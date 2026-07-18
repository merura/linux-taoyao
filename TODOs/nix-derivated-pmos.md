# TODO: turn the taoyao kernel build into a real Nix derivation

Right now (`shell.nix` + the steps in `../README.md`) the kernel is built
by hand: `nix-shell shell.nix`, then manual `export`s and `make` in
`kernel-taoyao/`. That's fine for getting the first boot working, but it
isn't reproducible as a single command and isn't reusable outside this
shell. Once the pmOS port actually boots, wrap it properly.

## Goal

A `linux-taoyao.nix` (or `pkgs/linux-taoyao/default.nix`) derivation that,
given the `kernel-taoyao` source (fetched via `fetchgit`, pinned to a
specific commit on `taoyao-s-oss` — not a floating branch), produces
`Image` + the taoyao dtb as build outputs, with `nix-build` as the only
command needed. This is also the `kernel/default.nix` piece the dual
pmOS + mobile-nixos repo in `../dual-build.md` will need — see that file.

## What has to move into the derivation

From the current manual process (`../README.md` steps 2-5):

1. **Shebang patch** — do it as a `postPatch` (`sed` over `#!/bin/bash`
   shebangs), not a mutation of a live checkout.
2. **`fetchgit` pinned to a commit**, not `--branch taoyao-s-oss` floating
   HEAD — reproducibility requires a fixed rev.
3. **Toolchain**: `clang` + `lld` + `llvmPackages.bintools` +
   `pkgsCross.aarch64-multiplatform.buildPackages.binutils`, same as
   `shell.nix` now, but as `nativeBuildInputs`.
4. **`LLVM_IAS=0`, `CROSS_COMPILE=aarch64-unknown-linux-gnu-`,
   `DISABLE_WRAPPER=1`** as derivation-level `makeFlags`/env, with a
   comment explaining *why* each exists (see `../README.md` step 3 — don't
   just copy the flags, copy the reasoning so a future re-read isn't
   confused when nixpkgs' clang version moves again and one of these
   stops being necessary).
5. **defconfig generation** (`scripts/gki/generate_defconfig.sh`) as a
   `preConfigure` or its own derivation phase — currently a separate
   manual step, should happen automatically before `Image`/`dtbs`.
6. **Output**: `$out/Image`, `$out/dtbs/*.dtb` (or whatever
   `linux-xiaomi-taoyao`'s pmaports `APKBUILD` ends up expecting — check
   `../pmaports-local/device/testing/linux-xiaomi-taoyao/` once that's
   written, keep the two in sync).

## Open questions to resolve when doing this

- Does `nixpkgs`' clang version drift ever require bumping `LLVM_IAS`/
  `DISABLE_WRAPPER` again, or re-checking the LSE atomics bug? Worth a
  comment pointing at the relevant nixpkgs clang version at derivation
  write time so future breakage is easy to diagnose.
- Should this live in this repo, or get upstreamed as a proper
  `pkgs/os-specific/linux/kernel/taoyao.nix`-style thing eventually if
  mobile-nixos support materializes (see `../dual-build.md`)?
- Once `pmbootstrap`'s own APKBUILD packages the kernel, does duplicating
  a Nix derivation for the same build actually pull its weight, or is it
  only worth it once mobile-nixos work starts? Bias: don't build this
  until we actually need it twice (pmOS APKBUILD + mobile-nixos), YAGNI
  otherwise.
