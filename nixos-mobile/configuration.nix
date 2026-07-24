# Minimal headless system for xiaomi-taoyao.
#
# No GUI: console only, with SSH over the USB gadget for debugging --
# same shape as the postmarketOS setup (device is 172.16.42.1, host gets
# 172.16.42.2).
{ config, lib, pkgs, ... }:

let
  deviceAddress = "172.16.42.1";
  hostAddress = "172.16.42.2";
  prefixLength = 24;
  usbInterface = "usb0";
in
{
  # ---------------------------------------------------------------------
  # Base
  # ---------------------------------------------------------------------
  system.stateVersion = "26.05";

  networking.hostName = "taoyao";

  time.timeZone = "Asia/Almaty";
  i18n.defaultLocale = "en_US.UTF-8";

  # Keep the closure small; this is a debug/bring-up system.
  documentation.enable = false;
  documentation.nixos.enable = false;

  # The Qualcomm/Xiaomi blobs are unfree and unredistributable. Allow only
  # those, rather than unfree in general. (mobile-nixos also builds a
  # `-zstd` compressed variant, hence the prefix match.)
  nixpkgs.config.allowUnfreePredicate = pkg:
    lib.hasPrefix "firmware-xiaomi-taoyao" (lib.getName pkg);

  # sxmo-utils depends on youtube-dl for video downloads. It's marked
  # insecure in this nixpkgs revision, but only as an "unmaintained,
  # migrate to yt-dlp" advisory -- no actual CVE list (unlike libsoup2,
  # which is excluded outright below via the mmsd-tng stub). Allowing it
  # is a reasonable call for this feature.
  nixpkgs.config.permittedInsecurePackages = [
    "python3.13-youtube-dl-2021.12.17"
  ];

  # mobile-nixos' `gadget-tool` (`gt`, used by adbd's stage-2 systemd unit
  # to enable the USB gadget) has a CMakeLists.txt with a
  # cmake_minimum_required below what current CMake supports at all
  # ("Compatibility with CMake < 3.5 has been removed"). Not fixable by
  # bumping cmake_minimum_required ourselves without patching upstream
  # source; the documented escape hatch is this policy-version override.
  nixpkgs.overlays = lib.mkAfter [
    (final: prev: {
      gadget-tool = prev.gadget-tool.overrideAttrs (old: {
        cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" ];
      });

      # `light` and `pn` were both removed from nixpkgs (unmaintained /
      # upstream archived). sxmo-utils lists both as build dependencies but
      # neither is actually invoked by any of its scripts (checked) -- these
      # only need to satisfy callPackage's argument resolution, not provide
      # working commands at runtime.
      light = prev.brightnessctl;
      pn = prev.writeShellScriptBin "pn" ''
        echo "pn: stub (upstream removed from nixpkgs, unused by sxmo-utils scripts)" >&2
        exit 1
      '';

    })
  ];

  environment.systemPackages = with pkgs; [
    htop
    usbutils
    pciutils
    strace
    file
    fastfetch
  ];

  # ---------------------------------------------------------------------
  # Users
  # ---------------------------------------------------------------------
  users.mutableUsers = false;

  users.users.root = {
    hashedPassword = null;
    initialPassword = "1234";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMYcdiZTkmjVhqK+IEDv6Q9bSSyc7LkWK3vyfsPkVMen"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmpu/fDlXWg4VsFdZ2bqi02QQM74zux7LprQriqbRsn"
    ];
  };

  users.users.user = {
    isNormalUser = true;
    initialPassword = "1234";
    extraGroups = [ "wheel" "video" "input" "dialout" "networkmanager" ];
    openssh.authorizedKeys.keys =
      config.users.users.root.openssh.authorizedKeys.keys;
  };

  # Passwordless sudo, as on the pmOS install.
  security.sudo.wheelNeedsPassword = false;

  # ---------------------------------------------------------------------
  # SSH over USB gadget (debug access)
  # ---------------------------------------------------------------------
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
      # Bring-up convenience; keys are installed above.
      PasswordAuthentication = true;
    };
  };

  # Static address on the USB gadget interface so the host can always reach
  # the device at a known IP, exactly like pmOS does.
  systemd.network = {
    enable = true;
    networks."10-usb-gadget" = {
      matchConfig.Name = usbInterface;
      address = [ "${deviceAddress}/${toString prefixLength}" ];
      networkConfig = {
        DHCPServer = true;
        IPv6AcceptRA = false;
      };
      dhcpServerConfig = {
        PoolOffset = 2;
        PoolSize = 4;
        # This is a USB debug link, not a real uplink -- don't advertise a
        # default gateway or DNS, since a connecting host's DHCP client
        # would otherwise happily replace its real default route (wifi/
        # ethernet) with this dead-end USB link, breaking its actual
        # internet connectivity. Only hand out an address/subnet.
        EmitRouter = false;
        EmitDNS = false;
      };
      linkConfig.RequiredForOnline = false;
    };
  };

  networking.useNetworkd = true;
  networking.useDHCP = false;

  # mobile-nixos (or one of the desktop-manager modules) enables
  # NetworkManager by default regardless -- make sure it never takes over
  # the USB debug link from systemd-networkd.
  networking.networkmanager = {
    enable = true;
    unmanaged = [ usbInterface ];
  };

  # RE-TESTING (previously left off): wifi's firmware (ath11k/wcn6750)
  # loads through the same qcom_q6v5_pas/remoteproc stack that was
  # blacklisted below to fix the USB-carrier-loss bug (dmesg confirmed:
  # "ath11k: failed to get rproc" without PAS) -- so testing wifi
  # necessarily means un-blacklisting PAS too (see below), which is
  # exactly what caused the original USB instability. This combination
  # (PAS un-blacklisted + wifi enabled, on top of everything fixed since
  # then -- never-suspend, etc.) has never been soak-tested. Needs an
  # unattended multi-minute reboot test before trusting it.
  # NetworkManager handles wifi association itself (its own internal
  # wpa_supplicant integration) -- networking.wireless.enable (the
  # standalone wpa_supplicant module) is mutually exclusive with it and
  # isn't needed here.

  # ath11k needs its regulatory-domain firmware blob to associate at all.
  hardware.wirelessRegulatoryDatabase = true;

  # HISTORY: with depmod enabled, `usb0` (and the whole USB link, not just
  # the network function) reliably failed to establish/keep carrier from
  # early boot onward. Root-caused to qcom_q6v5_pas (the shared "PAS"
  # loader for ADSP/CDSP/modem remoteproc firmware): zstas (this kernel
  # fork's maintainer) reported in github.com/sc7280-mainline/linux PR #11
  # that without his qcom_battmgr timing patch "my DE just freezes in
  # 5-10 seconds after the startup" -- an early-boot timing race between
  # qcom_battmgr and the APR/audio service IDs that come up during ADSP
  # boot, starving USB (or whatever else) of clock/timing resources.
  # Blacklisting the whole PAS loader sidestepped the race.
  #
  # PAS is un-blacklisted now to re-test wifi (ath11k's firmware is
  # *itself* a PAS-loaded remoteproc instance, so wifi and the PAS
  # blacklist were mutually exclusive) -- needs an unattended multi-minute
  # soak test to confirm the USB bug doesn't resurface with this exact
  # combination (PAS enabled + wifi + everything else fixed since, e.g.
  # sxmo's never-suspend). If it does resurface, PAS goes back on the
  # blacklist and wifi goes with it.
  #
  # Bluetooth (hci_uart/btqca, same WCN6750 combo chip) stays blacklisted
  # -- not requested, never tested.
  boot.blacklistedKernelModules = [
    "hci_uart" "btqca" "bluetooth"
  ];

  # Don't let the firewall get in the way of USB debugging.
  networking.firewall.enable = false;

  # ATTEMPT: keep wifi (wpss, a PAS-loaded remoteproc instance) while
  # avoiding the USB-carrier-loss race, which zstas's own PR discussion
  # ties to ADSP timing specifically ("without that patch my DE just
  # freezes in 5-10 seconds after the startup"). wpss (wifi) is a
  # separate remoteproc instance from adsp/cdsp under the same
  # qcom_q6v5_pas driver -- module-level blacklisting can't target just
  # one instance, so this stops adsp/cdsp the instant their remoteproc
  # device node appears (before their own firmware-boot sequence can run
  # far enough to race with USB init), while leaving wpss/modem alone.
  # UNVERIFIED: confirmed a *live* stop (after boot) does NOT retroactively
  # fix USB once it's already failed to establish carrier -- this only
  # has a chance of working if it intervenes early enough at boot,
  # which needs an actual reboot to test.
  services.udev.extraRules = ''
    SUBSYSTEM=="remoteproc", ATTR{name}=="adsp", ATTR{state}="stop"
    SUBSYSTEM=="remoteproc", ATTR{name}=="cdsp", ATTR{state}="stop"
  '';

  # Any libseat-based Wayland compositor (phoc, kwin_wayland, sway) needs
  # systemd-logind to mark its session "active" on a seat before it'll open
  # the DRM device. Every VT (tty1..tty6) gets autologin as root, since the
  # autologin override lands on the getty@.service *template*, not just
  # tty1 -- with more than one VT auto-spawned, whichever VT last had
  # kernel-console focus at boot becomes logind's "active" session, and if
  # that isn't the compositor's own tty1 session, its libseat backend waits
  # forever ("Timeout waiting session to become active") and never opens
  # the DRM device. This device has one physical screen, so there's no
  # reason to auto-spawn more than one VT in the first place. Shared across
  # all DE variants (Phosh/Plasma Mobile/SXMO), not just Phosh.
  services.logind.settings.Login.NAutoVTs = 1;

  # ---------------------------------------------------------------------
  # Console
  # ---------------------------------------------------------------------
  # No console autologin -- anyone with physical/USB access would otherwise
  # get an unauthenticated root shell on tty1. SSH access (key-based) and
  # each DE's own login/session flow are the intended access paths; a
  # console login still works, it just requires the password now.

  # Enabled so `nixos-rebuild switch --target-host` can update stage-2
  # (packages/services/users/etc.) without a full rebuild+reflash+reboot
  # cycle. Only kernel/initrd (stage-1) changes still need a reflash.
  nix.enable = true;

  # ---------------------------------------------------------------------
  # Kernel image filename
  # ---------------------------------------------------------------------
  # mobile-nixos' initrd-kernel.nix sets `system.boot.loader.kernelFile`
  # from `mobile.boot.stage-1.kernel.package.file` (a passthru attribute),
  # but `kernel-builder` never actually sets `.file` on its output even
  # though its own `target` option computes the real produced filename
  # (here "Image.gz", since our kernel builds with isCompressed = "gz").
  # Without this, the generic nixpkgs kernel-image sanity check
  # (nixos/modules/system/boot/kernel.nix) falls back to its own default
  # ("Image") and fails: "The bootloader cannot find the proper kernel
  # image." -- that check runs unconditionally whenever boot.kernel.enable
  # is true, regardless of mobile-nixos using its own boot mechanism.
  system.boot.loader.kernelFile = "Image.gz";
}
