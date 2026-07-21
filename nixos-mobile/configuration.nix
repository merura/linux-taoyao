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

  environment.systemPackages = with pkgs; [
    htop
    usbutils
    pciutils
    strace
    file
  ];

  # ---------------------------------------------------------------------
  # Users
  # ---------------------------------------------------------------------
  users.mutableUsers = false;

  users.users.root = {
    # Same throwaway password as the pmOS bring-up. Change it.
    hashedPassword = null;
    initialPassword = "pmos1234";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMYcdiZTkmjVhqK+IEDv6Q9bSSyc7LkWK3vyfsPkVMen"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmpu/fDlXWg4VsFdZ2bqi02QQM74zux7LprQriqbRsn"
    ];
  };

  users.users.user = {
    isNormalUser = true;
    initialPassword = "pmos1234";
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
      };
      linkConfig.RequiredForOnline = false;
    };
  };

  networking.useNetworkd = true;
  networking.useDHCP = false;

  # WiFi is available (ath11k/wcn6750); leave it managed but off by default.
  networking.wireless.enable = lib.mkDefault false;

  # Don't let the firewall get in the way of USB debugging.
  networking.firewall.enable = false;

  # ---------------------------------------------------------------------
  # Console
  # ---------------------------------------------------------------------
  # Getty on the framebuffer console so the screen is usable once the
  # panel workaround has run.
  services.getty.autologinUser = lib.mkDefault "root";

  # Nix on-device is not useful for a cross-built bring-up image and costs
  # a lot of closure size.
  nix.enable = lib.mkDefault false;

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
