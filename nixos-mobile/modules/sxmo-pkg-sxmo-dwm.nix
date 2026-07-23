# Local copy of sxmo-nix's pkgs/sxmo-dwm/default.nix, patched for this
# nixpkgs revision:
#
# 1. The sxmo-dwm patchset (multikey, swallow, dock, etc.) includes
#    X11/Xlib-xcb.h, which needs libxcb's headers directly (dwm's own
#    upstream buildInputs -- libX11, libXinerama, libXft -- don't pull
#    xcb dev headers onto the include path even though libX11 depends on
#    libxcb at the library level). Upstream nixpkgs's plain `dwm` package
#    never hits this because it doesn't use Xlib-xcb.h. Add
#    `pkgs.xorg.libxcb` to buildInputs to fix the missing-header build
#    failure ("fatal error: xcb/xcb.h: No such file or directory").
#
# 2. dwm.c calls XkbSetDetectableAutoRepeat() without including
#    X11/XKBlib.h (where it's declared), which the old GCC this code was
#    written against only warned about. GCC 14 (in this nixpkgs) promotes
#    implicit-function-declaration to a hard error by default, so the
#    build now fails outright. Patch the missing #include in postPatch
#    rather than relaxing the compiler flag, since it's a single,
#    identifiable, correct fix.
#
# 3. Beyond that one, the rest of the sxmo-dwm patchset (multikey timer
#    dispatch, wide-character handling, scheme-color helpers) is a stack
#    of several old, independently-written community patches that call
#    each other's functions before their point of definition/prototype,
#    and in one case pass a `char **` where `drw_scm_create` expects
#    `const char **`. This all used to be warn-only; GCC 14/15 promotes
#    both implicit-function-declaration and incompatible-pointer-types to
#    hard errors by default. Rather than hand-patch prototypes across
#    every one of these stacked third-party patches (high effort, easy to
#    get subtly wrong), demote just those two diagnostics back to
#    warnings for this package specifically -- this is pre-existing,
#    already-in-use-elsewhere patch code, not new/untested code we're
#    writing ourselves.
{ pkgs, lib, fetchFromSourcehut, dwm, ... }:

(dwm.overrideAttrs (oldAttrs: rec {
  name = "smxo-dwm";
  version = "6.2.17";

  src = fetchFromSourcehut {
    owner = "~mil";
    repo = "sxmo-dwm";
    rev = version;
    sha256 = "sha256-/q4QdXWDlNkhsLudAehAxofDs7BCMRAPna0S9gDZjZs=";
  };

  buildInputs = (oldAttrs.buildInputs or [ ]) ++ [ pkgs.xorg.libxcb ];

  postPatch = (oldAttrs.postPatch or "") + ''
    sed -i '0,/#include <X11\/Xutil.h>/s//#include <X11\/Xutil.h>\n#include <X11\/XKBlib.h>/' dwm.c
  '';

  NIX_CFLAGS_COMPILE = "-Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types";

  meta = with lib; {
    description = "Dwm for sxmo - multikey, swallow, dock, among other patches.";
    homepage = "https://git.sr.ht/~mil/sxmo-dwm";
    license = licenses.mit;
    platforms = platforms.linux;
    maintainers = with maintainers; [ wentam ];
  };
}))
