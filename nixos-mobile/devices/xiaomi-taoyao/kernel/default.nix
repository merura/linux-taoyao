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
, buildPackages
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

  # drivers/gpu/drm/msm/registers/gen_header.py is invoked by the build
  # (Adreno register header generation) and needs python3 on the build
  # host. The postmarketOS APKBUILD for this exact kernel declares python3
  # as a makedepend for the same reason; mobile-nixos' kernel-builder does
  # not include it by default.
  nativeBuildInputs = [ buildPackages.python3 ];

  # `make modules_install`'s own depmod invocation is silently skipped
  # somewhere in this cross-compiled build path: the installed modules
  # tree only ever has modules.builtin/modules.order (raw kernel-build
  # artifacts), never modules.dep/modules.alias/modules.symbols (the
  # depmod-generated indices). Without those, udev has no MODALIAS ->
  # module mapping, so *no* module ever auto-loads on hotplug -- this is
  # what silently broke the touchscreen (hid-goodix-spi.ko exists and
  # insmod's fine by hand, it just never gets loaded automatically).
  #
  # NOTE: postmarketOS's APKBUILD for this same kernel commit has no
  # equivalent workaround -- it relies on the kernel's own built-in
  # depmod call, which succeeds there because Alpine's abuild chroot has
  # depmod ambiently on PATH (unlike our hermetic Nix sandbox). Touch
  # autoloads fine on pmOS with no instability, so depmod itself isn't
  # unsafe; wifi (ath11k, blacklisted in configuration.nix) is the
  # current suspect for the USB-destabilizing crash seen with this
  # enabled previously -- isolating one driver at a time.
  postInstall = ''
    echo ":: Running depmod (builder's own depmod invocation is skipped for this cross-build)"
    version=$(ls $out/lib/modules)
    ${buildPackages.kmod}/bin/depmod -b $out -F $out/System.map "$version"
  '';
}
