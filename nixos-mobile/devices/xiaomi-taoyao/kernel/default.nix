# Kernel for xiaomi-taoyao.
#
# Based on Stanislav Zaikin's (zstas) SM7325 tree at 0b867a74 (the commit
# that boots with a working panel; earlier commits, e.g. upstream_panel's
# 50ab7f30, hang or fail to light the display), plus one commit on top:
# a fix (researched and pushed by an agent, see commit message on the
# fork) for a real kernel bug where the ADSP remoteproc coming up at any
# point permanently kills the USB gadget link. Root cause: usb_1's
# devicetree override never set dr_mode, so dwc3 defaulted to OTG and
# registered a USB role switch; the instant ADSP's firmware exposes
# charger_pd, pmic-glink's UCSI client calls
# usb_role_switch_set_role() on it, and dwc3_set_mode() tears down the
# already-running gadget to switch roles. Setting
# dr_mode = "peripheral" on &usb_1 stops dwc3 from ever registering
# that role switch, so UCSI's later call has nothing to act on.
# Confirmed via multiple live reboot tests that USB reliably died
# whenever adsp ran (even a 30s-delayed, no-race modprobe well after
# USB already had carrier), ruling out a boot-time-race explanation --
# this devicetree fix is the actual, targeted root cause.
#
# NEEDS ON-DEVICE VERIFICATION: this fix was compile-verified (dtc)
# but not yet reboot-tested when first wired in here.
#
# The config is the postmarketOS config-xiaomi-taoyao.aarch64, with
# CONFIG_DRM_FBDEV_EMULATION=y added -- without it the DRM driver never
# creates /dev/fb0 and the screen stays black after the bootloader hands off.
{ mobile-nixos
, fetchFromGitHub
, buildPackages
, stdenv
, writeShellScriptBin
, lib

# ccache for this cross-compile: never cache-hit from a substituter
# regardless (own out-of-tree source/commit), so local object caching is
# the only speedup available across config-only rebuilds. Needs
# `nix.settings.sandbox = "relaxed";` and a writable /var/cache/ccache
# (group "nixbld") on the *host* -- see ~/dotfiles/hosts/t14s/configuration.nix
# -- since Nix's sandbox has no persistent host directory across separate
# builds otherwise. Default on since that host config is already applied;
# override with `pkgs.callPackage ./kernel { enableCcache = false; }` on a
# machine without the sandbox-relaxed + /var/cache/ccache setup, or if
# __noChroot ever needs to be avoided for some other reason.
, enableCcache ? true

, ...
}:

let
  ccacheCC = writeShellScriptBin "kernel-ccache-cc" ''
    export CCACHE_DIR="/var/cache/ccache"
    exec ${buildPackages.ccache}/bin/ccache ${stdenv.cc}/bin/${stdenv.cc.targetPrefix}cc "$@"
  '';
in

mobile-nixos.kernel-builder {
  version = "7.1.0-rc5";
  configfile = ./config.aarch64;

  src = fetchFromGitHub {
    owner = "merura";
    repo = "sm6115_mainline";
    rev = "4dbe40fcaf30674e8d1607e81622a7d171ec051c";
    hash = "sha256-RXDU7u3EJux8uFywuec+3kUfi8wG8u2KyDrXa//evJ0=";
  };

  # The pmOS config builds modules (CC [M] ...), so keep them.
  isModular = true;
  isCompressed = "gz";

  # drivers/gpu/drm/msm/registers/gen_header.py is invoked by the build
  # (Adreno register header generation) and needs python3 on the build
  # host. The postmarketOS APKBUILD for this exact kernel declares python3
  # as a makedepend for the same reason; mobile-nixos' kernel-builder does
  # not include it by default.
  nativeBuildInputs = [ buildPackages.python3 ] ++ lib.optional enableCcache buildPackages.ccache;

  # See ccacheCC above. `make CC=...` on the command line always wins
  # over kernel-builder's own default `CC=` entry earlier in its
  # makeFlags list (later command-line variable assignments override
  # earlier ones), so this doesn't need to replace anything, just append.
  makeFlags = lib.optional enableCcache "CC=${ccacheCC}/bin/kernel-ccache-cc";

  # Opts this derivation out of Nix's build sandbox (requires
  # `nix.settings.sandbox = "relaxed";` on the host) so ccache can read
  # and write its persistent cache directory across separate builds --
  # normally impossible since the sandbox gives each build a fresh,
  # isolated filesystem view with no access to host state like this.
  __noChroot = enableCcache;

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
