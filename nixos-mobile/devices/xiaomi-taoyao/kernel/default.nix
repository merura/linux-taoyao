# Kernel for xiaomi-taoyao.
#
# Uses Stanislav Zaikin's (zstas) SM7325 tree. This exact commit is the one
# that boots with a working panel; earlier commits (e.g. upstream_panel's
# 50ab7f30) hang or fail to light the display.
#
# The config is the postmarketOS config-xiaomi-taoyao.aarch64, with
# CONFIG_DRM_FBDEV_EMULATION=y added -- without it the DRM driver never
# creates /dev/fb0 and the screen stays black after the bootloader hands off.
{ mobile-nixos
, fetchFromGitHub
, ...
}:

mobile-nixos.kernel-builder {
  version = "7.1.0-rc5";
  configfile = ./config.aarch64;

  src = fetchFromGitHub {
    owner = "zstas";
    repo = "sm6115_mainline";
    rev = "0b867a7442d7d780dee52a04904a758386761f57";
    hash = "sha256-z+1JuqlNqqJ9gjALXK2d0qw7Ha+/oe/KcQq4lf13OMw=";
  };

  # The pmOS config builds modules (CC [M] ...), so keep them.
  isModular = true;
  isCompressed = "gz";
}
