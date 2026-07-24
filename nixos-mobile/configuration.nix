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

  # wifi's firmware (ath11k/wcn6750) loads through the qcom_q6v5_pas
  # remoteproc stack (the "wpss" instance), same as adsp/cdsp/modem.
  # NetworkManager handles wifi association itself (its own internal
  # wpa_supplicant integration) -- networking.wireless.enable (the
  # standalone wpa_supplicant module) is mutually exclusive with it and
  # isn't needed here.

  # ath11k needs its regulatory-domain firmware blob to associate at all.
  hardware.wirelessRegulatoryDatabase = true;

  # HISTORY: usb0 used to reliably lose/never establish carrier the
  # instant the adsp remoteproc came up, at any point after boot (not a
  # timing race -- confirmed via a fully deterministic test: blacklisting
  # qcom_q6v5_pas entirely, then modprobing it back 30+ seconds after
  # usb0 already had confirmed carrier, still killed USB within seconds).
  # Root-caused (see kernel commit "arm64: dts: qcom: taoyao: force
  # usb_1 dr_mode to peripheral" on the pinned kernel fork/rev): usb_1's
  # devicetree override never set dr_mode, so dwc3 defaulted to OTG and
  # registered a USB role switch; the instant adsp's firmware exposes
  # charger_pd, pmic-glink's UCSI client calls usb_role_switch_set_role()
  # on it, and dwc3_set_mode() tears down the already-running gadget to
  # switch roles. Fixed at the kernel/devicetree level (dr_mode forced to
  # "peripheral", so no role switch is ever registered) -- no NixOS-level
  # boot-sequencing workaround needed anymore. All four remoteproc
  # instances (modem/adsp/wpss/cdsp) now autoboot normally.
  #
  # Bluetooth (hci_uart/btqca, same WCN6750 combo chip) stays blacklisted
  # -- not requested, never tested.
  boot.blacklistedKernelModules = [
    "hci_uart" "btqca" "bluetooth"
  ];

  # TRIED AND REVERTED: the debug-snapshot.service periodic diagnostic
  # (see below) caught /sys/class/power_supply/ucsi-source-psy-*/uevent
  # showing POWER_SUPPLY_USB_TYPE=C [PD] PD_PPS on a dead-USB boot,
  # suggesting UCSI's PD/PPS power negotiation (a mechanism entirely
  # separate from the dr_mode=peripheral fix already applied, since
  # UCSI's PD policy engine runs independent of dwc3's data-role state
  # machine) might be what kills the link. Tested unbinding ucsi_glink's
  # auxiliary-bus device (pmic_glink.ucsi.0) via udev as early as
  # possible, before any PD negotiation. Result: worse, not better --
  # "UCSI version unknown" in dmesg (interrupted mid-init) and the UDC
  # never left "default" state at all, i.e. the gadget didn't connect
  # even once. So UCSI being present is *necessary* for the gadget to
  # connect in the first place; something about it *completing*
  # negotiation is what kills it later, not its mere presence. Reverted.

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
