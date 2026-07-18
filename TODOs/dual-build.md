# TODO: one Nix repo, two install targets (postmarketOS + mobile-nixos)

Supersedes the earlier plan of "do pmOS, then separately redo everything
for mobile-nixos later." Instead: one Nix-based repo/flake with the
taoyao device facts and kernel build defined once, producing artifacts
consumable by both postmarketOS and mobile-nixos. Still explicitly
deferred until the current postmarketOS port actually boots — see
"Not yet done" at the bottom.

Project reference: [nix-community/mobile-nixos](https://github.com/nix-community/mobile-nixos)
(sometimes called "nixos-mobile") for the NixOS-mobile side.

## Why this is realistic

The hard, device-specific parts we're already doing for pmOS are
distro-agnostic facts about the taoyao hardware/bootloader, not
pmOS-specific:

- Boot image format: Android header v3, `boot_a` (kernel+ramdisk) +
  `vendor_boot_a` (dtb + vendor ramdisk). See `../README.md` step 1.
- Confirmed load offsets: kernel `0x8000`, ramdisk `0x1000000`, tags
  `0x100`, dtb `0x1f00000`, page size 4096.
- The stock `vendor_boot.img` dtb blob is 10 concatenated QCDT-format
  DTBs — neither pmOS's `mkbootimg` tooling nor (as far as known so far)
  mobile-nixos's has first-class QCDT support, so both distros hit the
  same "need a single plain dtb" requirement.
- The kernel itself: Xiaomi's `taoyao-s-oss` downstream source
  (`MiCode/Xiaomi_Kernel_OpenSource`), Linux 5.4.86, `lahaina`/SM7325
  platform. Same source, same build, for both distros' kernel packages.
- The Nix build workarounds for this kernel + modern Clang
  (`LLVM_IAS=0`, `DISABLE_WRAPPER=1` — see `../README.md` step 3) apply
  identically regardless of which distro consumes the output.

A kernel built once, from one pinned derivation, is strictly better than
building it twice (once by hand for pmOS, once inside mobile-nixos)
with two chances to drift out of sync.

## Proposed shape

```
flake.nix
lib/
  taoyao-device.nix     # shared facts: header version, load offsets,
                         # dtb path, kernel source pin (see below)
kernel/
  default.nix           # the derivation from nix-derivated-pmos.md —
                         # this file's whole job is to exist so both
                         # targets below can depend on it
pmos/
  ...                    # whatever postmarketOS-side packaging needs
                         # to consume kernel/default.nix's output
nixos-mobile/
  device.nix             # mobile-nixos device definition, imports
                         # lib/taoyao-device.nix for the shared facts
```

`kernel/default.nix` is exactly the derivation `nix-derivated-pmos.md`
already describes — that TODO isn't obsolete, it's now "step 1 of this
one." Do that first regardless.

## The actual open problem: can pmOS consume a Nix-built kernel?

postmarketOS itself is Alpine/`apk`/`abuild`-based, not Nix-native — we
are not trying to make pmOS's rootfs Nix-built, that's out of scope and
not a goal here. The only question is narrower: can
`linux-xiaomi-taoyao`'s `APKBUILD` just `cp` in the `Image`/dtb produced
by `nix build .#kernel` instead of compiling them itself?

Reasons to think yes: a compiled kernel `Image` binary has no libc
dependency (it's not a userspace ELF linked against glibc/musl), so
there's no musl-vs-glibc conflict in shipping a Nix(glibc-host)-built
`Image` into an Alpine(musl) rootfs. This is the same reason cross
distros already do this kind of thing for kernel binaries.

Reasons it might be more friction than it's worth: pmbootstrap's own
build model assumes `abuild` compiles everything inside its own Alpine
chroot for reproducibility purposes; special-casing one package to
instead `cp` a Nix store path in breaks that model and might fight the
tooling more than it saves. Needs an actual attempt, not just reasoning
about it here, before deciding.

## What's actually mobile-nixos-specific

1. **`device.nix`** (mobile-nixos' rough equivalent of pmOS's
   `deviceinfo`) — device identity, boot method, partition layout,
   pointer to `kernel/default.nix`.
2. **Boot image assembly in Nix** — mobile-nixos has its own
   `mkbootimg`-equivalent build logic; need to check whether it already
   handles header v3 / `vendor_boot` splits, or whether that's another
   gap to fill (same category of gap pmOS has re: QCDT — check both
   before assuming either "just works").
3. **Whatever mobile-nixos' generic Qualcomm/`lahaina`-family support
   currently covers** — check if `mobile-nixos` already has partial
   SM7325 support from another device (a `sm7325`-family device there
   would be the equivalent shortcut `device-nothing-spacewar` was for
   the pmOS `deviceinfo` in this session — see `../README.md` step 6).
   Not checked yet.
4. **Rootfs/init differences** — actual NixOS userspace instead of
   Alpine; unrelated to anything done so far, standard mobile-nixos
   device-bringup work once boot works at all.

## Not yet done, don't assume otherwise

- Nobody has confirmed pmOS actually boots on taoyao yet. Don't start
  this until that's true — the dual-build structure is only worth
  designing once we know the underlying kernel/config actually works on
  the device.
- Nobody has checked whether mobile-nixos has *any* existing SM7325 or
  `lahaina`-platform device to use as a reference, the way
  `device-nothing-spacewar` was used for pmOS's `deviceinfo`. Check
  `nix-community/mobile-nixos`'s device list when this starts.
- Whether `linux-xiaomi-taoyao`'s `APKBUILD` can actually consume a
  Nix-built `Image` (see above) is unverified reasoning, not a tested
  fact.
