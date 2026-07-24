# Local reimplementation of sxmo-nix's top-level default.nix, with
# mmsd-tng (MMS support) replaced by a stub.
#
# Why not just override `mmsd-tng` via an overlay in configuration.nix:
# sxmo-nix's own default.nix builds mmsd-tng from ITS OWN local
# ./pkgs/mmsd-tng path (not a real nixpkgs attribute), and sxmo-utils reads
# that binding directly from the same `rec` scope -- there's no nixpkgs
# attribute name to intercept from outside, so the substitution has to
# happen here instead.
#
# mmsd-tng hard-depends on libsoup2 (marked insecure in this nixpkgs
# revision -- many unpatched CVEs, upstream EOL since 2023), and there's no
# cellular modem/SIM wiring in this config at all yet, so stubbing it out
# is the same call as excluding `chatty` from the Phosh build over its
# `olm` dependency.
{ sxmoNixSrc, pkgs }:

let
  mmsd-tng-stub = pkgs.runCommand "mmsd-tng-stub" { } ''
    mkdir -p $out/bin
    for bin in mmsdtng create-hex-array decode-mms mmsctl; do
      cat > "$out/bin/$bin" <<'EOF'
    #!/bin/sh
    echo "$0: stub (MMS support disabled, no modem/SIM wiring in this config)" >&2
    exit 1
    EOF
      chmod +x "$out/bin/$bin"
    done
  '';
in
rec {
  # Local patched copy: adds libxcb to buildInputs, see
  # sxmo-pkg-sxmo-dwm.nix for why.
  sxmo-dwm = pkgs.callPackage ./sxmo-pkg-sxmo-dwm.nix { };
  sxmo-st = pkgs.callPackage "${sxmoNixSrc}/pkgs/sxmo-st" { };
  sxmo-dmenu = pkgs.callPackage "${sxmoNixSrc}/pkgs/sxmo-dmenu" { };
  superd = pkgs.callPackage ./sxmo-pkg-superd.nix { };

  # tinydm's package.nix puts `busybox` in buildInputs, which puts
  # busybox's multi-call `find` (no -printf support) on PATH ahead of GNU
  # findutils for the *whole build*, breaking stdenv's own fixup-phase
  # `find -printf` calls (unrelated to tinydm itself). Nothing in the
  # installed scripts references busybox at runtime either (no wrapper),
  # so this buildInput looks vestigial -- drop it.
  tinydm = (pkgs.callPackage "${sxmoNixSrc}/pkgs/tinydm" { }).overrideAttrs (old: {
    buildInputs = pkgs.lib.filter (p: p != pkgs.busybox) old.buildInputs;
  });
  autologin = pkgs.callPackage "${sxmoNixSrc}/pkgs/autologin" { };
  proycon-wayout = pkgs.callPackage "${sxmoNixSrc}/pkgs/proycon-wayout" { };
  mnc = pkgs.callPackage ./sxmo-pkg-mnc.nix { };
  mmsd-tng = mmsd-tng-stub;
  # Local patched copy: fixes a missing _XOPEN_SOURCE define that breaks
  # the wcwidth() build under GCC 14, see sxmo-pkg-codemadness-frontends.nix.
  codemadness-frontends = pkgs.callPackage ./sxmo-pkg-codemadness-frontends.nix { inherit sxmoNixSrc; };
  vvmd = pkgs.callPackage "${sxmoNixSrc}/pkgs/vvmd" { };
  sxmo-utils = (pkgs.callPackage "${sxmoNixSrc}/pkgs/sxmo-utils" {
    inherit
      codemadness-frontends
      mmsd-tng
      mnc
      superd
      vvmd
      sxmo-dwm
      sxmo-dmenu
      sxmo-st
      ;
  }).overrideAttrs (old: {
    # foot's [colors] section was renamed to [colors-dark] (foot prints a
    # deprecation warning otherwise); sxmo-utils' shipped default still
    # uses the old name. Patching only the user's live copy at
    # ~/.config/foot/foot.ini doesn't stick: sxmo's own config-migration
    # check compares the user's file against THIS packaged default on
    # every session start, and resets/flags anything that differs. Fix
    # it at the source instead so the shipped default already matches.
    postInstall = (old.postInstall or "") + ''
      sed -i 's/^\[colors\]/[colors-dark]/' \
        "$out/share/sxmo/appcfg/foot.ini"

      # sxmo_common.sh's own PATH construction never includes iproute2 at
      # all, so `ip` resolves to busybox's stripped-down reimplementation
      # inside every sxmo session/terminal (not a PATH-ordering issue --
      # busybox is the *only* provider of `ip` in that context). Prepend
      # the real iproute2/util-linux bin dirs to the front of the PATH
      # sxmo_common.sh exports, so real `ip`/`dmesg`/etc. win over
      # busybox's built-ins without touching the many intentional
      # busybox aliases (find/grep/sed/etc.) sxmo sets up elsewhere in
      # that same file for portability with Alpine/postmarketOS.
      sed -i "s|^export PATH=\"|export PATH=\"${pkgs.iproute2}/bin:${pkgs.util-linux}/bin:|" \
        "$out/bin/sxmo_common.sh"
    '';
  });
}
