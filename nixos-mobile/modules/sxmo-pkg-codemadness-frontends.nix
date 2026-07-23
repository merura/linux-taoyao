# Local copy of sxmo-nix's pkgs/codemadness-frontends/default.nix, patched
# for this nixpkgs revision: the upstream Makefile's active (non-commented)
# CFLAGS block is the OpenBSD one, which never defines _XOPEN_SOURCE. On
# Linux/glibc, wcwidth(3) is only declared in <wchar.h> when
# _XOPEN_SOURCE >= 500 (or _GNU_SOURCE) is defined -- the Makefile even
# ships a commented-out "Linux" CFLAGS line with the right defines, it's
# just not the active one. This used to only be a warning; GCC 14 (in
# this nixpkgs) promotes implicit-function-declaration to a hard error,
# so the build now fails outright ("error: implicit declaration of
# function 'wcwidth'"). Fix by passing the same defines the Makefile's
# own commented-out Linux stanza already specifies, via CFLAGS.
{ stdenv, lib, fetchurl, libressl, glibc, sxmoNixSrc, ... }:

stdenv.mkDerivation rec {
  pname = "codemadness-frontends";
  version = "0.5";

  patches = [ "${sxmoNixSrc}/pkgs/codemadness-frontends/001-link-dynamically.patch" ];

  buildInputs = [ libressl glibc ];

  # NOTE: this must NOT be done via `makeFlags = [ "CFLAGS=-D_FOO -D_BAR" ]`
  # -- that string contains a space, and the generic builder's `make
  # ${makeFlags[@]}` passes it through unquoted, so make sees "-D_BAR" as
  # a second, bare positional argument (a make *option*, not part of the
  # CFLAGS value) and fails with "invalid option -- 'D'". Use
  # NIX_CFLAGS_COMPILE (an environment variable GCC's nixpkgs wrapper
  # appends automatically) instead, which doesn't go through make's
  # argv-splitting at all.
  NIX_CFLAGS_COMPILE = "-D_DEFAULT_SOURCE -D_XOPEN_SOURCE=700";

  makeFlags = [
    "RANLIB=${stdenv.cc.targetPrefix}ranlib"
  ];

  src = fetchurl {
    url = "https://www.codemadness.org/releases/frontends/frontends-${version}.tar.gz";
    sha256 = "sha256-8NKSfyIMSzaWTgIkFdcPTX/ECeQiasZPfZG1Ft/LOUw=";
  };

  installPhase = ''
    install -D reddit/cli $out/bin/reddit-cli
    install -D reddit/gopher $out/bin/reddit-gopher
    install -D duckduckgo/cli $out/bin/duckduckgo-cli
    install -D duckduckgo/gopher $out/bin/duckduckgo-gopher
    install -D youtube/cli $out/bin/youtube-cli
    install -D youtube/cgi $out/bin/youtube-cgi
    install -D youtube/gopher $out/bin/youtube-gopher
  '';

  meta = with lib; {
    description = "Frontends for duckduckgo, reddit, twitch, and youtube";
    homepage = "https://www.codemadness.org/";
    license = licenses.isc;
    platforms = platforms.linux;
    maintainers = with maintainers; [ wentam ];
  };
}
