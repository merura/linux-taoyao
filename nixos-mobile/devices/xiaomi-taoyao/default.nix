# Xiaomi 12 Lite 5G (taoyao), Qualcomm SM7325 / Snapdragon 778G+.
#
# Values here are ported from the working postmarketOS port; see
# ../../../linux-taoyao-2/README.md and taoyao.patch (deviceinfo).
{ config, lib, pkgs, ... }:

{
  imports = [
    ../../modules/soc-sm7325.nix
    ../../modules/panel-fix.nix
  ];

  mobile.device.name = "xiaomi-taoyao";
  mobile.device.identity = {
    name = "12 Lite 5G";
    manufacturer = "Xiaomi";
  };
  # Boots, display works, USB networking works. No audio/camera/GPU accel yet.
  mobile.device.supportLevel = "best-effort";

  mobile.hardware = {
    soc = "qualcomm-sm7325";
    ram = 1024 * 8;
    screen = {
      width = 1080;
      height = 2400;
    };
  };

  mobile.device.firmware = pkgs.callPackage ./firmware { };

  mobile.boot.stage-1 = {
    compression = "xz";
    kernel.package = pkgs.callPackage ./kernel { };

    # mobile-nixos only adds "rndis" to the USB gadget's feature list when
    # stage-1 networking is enabled (modules/initrd-usb.nix:
    # `usb.features = [] ++ optional cfg.networking.enable "rndis"`).
    # Without this, the gadget only ever exposed "adb" (from
    # mobile.adbd.enable below) -- the usb0 interface configured in
    # configuration.nix's systemd-networkd never had an actual rndis
    # function backing it, so SSH-over-USB never worked.
    networking.enable = true;
  };

  hardware.enableRedistributableFirmware = true;

  mobile.system.type = "android";
  mobile.system.android = {
    device_name = "taoyao";

    # This device uses dynamic partitions ("super"): the "system" logical
    # partition is only writable through `fastbootd` (a userspace daemon
    # normally supplied by AOSP recovery). Our own minimal initrd doesn't
    # implement fastbootd, and once it's flashed to both A/B slots it also
    # takes over the "boot to recovery" path, so real fastbootd becomes
    # unreachable entirely -- same problem postmarketOS hit, solved the same
    # way there: target `userdata` (a plain, huge physical partition) for
    # the rootfs instead, so it flashes with plain bootloader `fastboot
    # flash`. mobile-nixos finds root by filesystem label ("NIXOS_SYSTEM",
    # see modules/rootfs.nix) at boot, not by partition name, so this is
    # transparent to stage-1.
    system_partition_destination = "userdata";

    # A/B device. Note both slots must be flashed; the bootloader silently
    # falls back to the other slot after failed boots.
    ab_partitions = true;

    # deviceinfo_header_version="0"
    bootimg = {
      flash = {
        # Identical to the deviceinfo_flash_offset_* values.
        offset_base = "0x00000000";
        offset_kernel = "0x00008000";
        offset_ramdisk = "0x01000000";
        offset_second = "0x00000000";
        offset_tags = "0x00000100";
        pagesize = "4096";
      };
    };

    # deviceinfo_dtb="qcom/sm7325-xiaomi-taoyao" + deviceinfo_append_dtb="true"
    appendDTB = [ "dtbs/qcom/sm7325-xiaomi-taoyao.dtb" ];
  };

  # Matches what the device enumerated as under postmarketOS
  # (lsusb: 18d1:d001 Google Inc. Nexus 4).
  mobile.usb.mode = "gadgetfs";
  mobile.usb.idVendor = lib.mkDefault "18D1";
  mobile.usb.idProduct = lib.mkDefault "D001";
  mobile.usb.gadgetfs.functions = {
    adb = "ffs.adb";
    rndis = "rndis.usb0";
    mass_storage = "mass_storage.0";
  };

  # ADB in stage-1 (the initrd), not just stage-2. This is the only way to
  # get an interactive shell into the exact environment where a stage-1
  # boot-error screen (INIT_EXCEPTION) happens -- otherwise there is no
  # remote access at all until stage-2/networking comes up, which never
  # happens if stage-1 itself crashes.
  mobile.adbd.enable = true;
}
