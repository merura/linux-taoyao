# Qualcomm SM7325 (Snapdragon 778G+) SoC support.
#
# Mobile NixOS does not ship an SM7325 SoC module (it knows about sdm845,
# sc7180, sm6125, ...), and `mobile.hardware.soc` asserts that the named SoC
# exists in `mobile.hardware.socs`. So declare it here, out of tree.
#
# Modelled on mobile-nixos' modules/hardware-qualcomm.nix.
{ config, lib, ... }:

let
  inherit (lib) mkIf mkOption types;
  cfg = config.mobile.hardware.socs;
in
{
  options.mobile.hardware.socs.qualcomm-sm7325.enable = mkOption {
    type = types.bool;
    default = false;
    description = "Enable when SOC is SM7325 (Snapdragon 778G+)";
  };

  config = mkIf cfg.qualcomm-sm7325.enable {
    mobile.system.system = "aarch64-linux";

    # SM7325 devices are A/B, with a boot-control HAL equivalent.
    mobile.boot.boot-control.enable = lib.mkDefault true;

    # hardware-qualcomm.nix only applies these for the SoCs it knows about,
    # so set them here too.
    mobile.kernel.structuredConfig = [
      (helpers: with helpers; {
        ARCH_QCOM = lib.mkDefault yes;
      })
    ];
  };
}
