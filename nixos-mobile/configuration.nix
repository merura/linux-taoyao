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
    extraGroups = [ "wheel" "video" "input" "dialout" ];
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
  # NetworkManager by default regardless of our own wifi setting below --
  # harmless with ath11k blacklisted (no wifi hardware for it to manage),
  # but make sure it never takes over the USB debug link from
  # systemd-networkd regardless.
  networking.networkmanager.unmanaged = [ usbInterface ];

  # WiFi is available (ath11k/wcn6750), but its firmware loads through the
  # very same qcom_q6v5_pas/remoteproc stack blacklisted below to fix the
  # USB-carrier-loss bug (dmesg: "ath11k: failed to get rproc") -- this
  # isn't a case of wifi not needing PAS, the WCN6750 chip's firmware *is*
  # a PAS-loaded remoteproc instance, same as ADSP/CDSP. So wifi and the
  # USB fix are mutually exclusive as long as the whole PAS loader is
  # blacklisted. Leaving wifi off until there's a way to allow just the
  # wifi/WPSS rproc instance without also re-triggering the ADSP/CDSP
  # timing race zstas documented (see blacklist comment below).
  networking.wireless.enable = lib.mkDefault false;

  # With depmod enabled, `usb0` (and the whole USB link, not just the
  # network function -- the host's lsusb loses the device entirely too)
  # reliably fails to establish/keep carrier from early in boot onward,
  # for the rest of that session. The system itself stays otherwise fully
  # healthy the whole time (systemctl is-system-running: running, no
  # failed units, normal thermals) -- this is not a crash or a hang, just
  # USB link training failing, confirmed via periodic debug-snapshot
  # journal entries across the whole boot. Every one of these incidents
  # actually ended via a manual power-button press
  # ("systemd-logind: Power key pressed short. Powering off..."), not a
  # crash -- that's a red herring we chased for a while.
  #
  # Bluetooth (hci_uart/btqca, on the same WCN6750 combo chip) stays
  # blacklisted too -- not requested, and never tested in combination with
  # the PAS fix.
  #
  # qcom_q6v5_pas (the shared "PAS" loader for ADSP/CDSP/modem remoteproc
  # firmware) is the new suspect: zstas (this kernel fork's maintainer)
  # reported in github.com/sc7280-mainline/linux PR #11 that on this
  # exact device, without his qcom_battmgr timing patch "my DE just
  # freezes in 5-10 seconds after the startup" -- attributed to
  # ordering/timing sensitivity between qcom_battmgr and the APR/audio
  # service IDs that come up during ADSP boot. qcom_battmgr's own
  # "failed to send synthetic uevent: -11" messages have been present on
  # every single boot this whole session. This is a real, maintainer-
  # acknowledged early-boot timing race on this device/kernel, and a
  # very plausible source of "something else is being starved for
  # clock/timing resources" -- which would explain why USB specifically,
  # rather than a specific driver, is what loses out on any given boot.
  # We don't need audio/compute-DSP/cellular for the current headless
  # bring-up scope, so blacklisting the whole PAS loader sidesteps the
  # race entirely rather than trying to fix its timing.
  boot.blacklistedKernelModules = [
    "ath11k_ahb" "ath11k"
    "hci_uart" "btqca" "bluetooth"
    "qcom_q6v5_pas" "qcom_pil_info" "qcom_q6v5" "qcom_common"
  ];

  # Don't let the firewall get in the way of USB debugging.
  networking.firewall.enable = false;

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
