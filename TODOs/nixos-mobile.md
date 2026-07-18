# TODO: NixOS mobile port for taoyao (after postmarketOS works)

Longer-term goal, explicitly deferred until the postmarketOS port
actually boots. Tracked here so the reasoning from this session isn't
lost by the time we get to it.

Project: [nix-community/mobile-nixos](https://github.com/nix-community/mobile-nixos)
(sometimes still called "nixos-mobile") — builds real NixOS images for
phones, as opposed to pmOS's Alpine/musl base.

## Why this is realistic to defer, not skip

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
  platform. Same source works for both distros' kernel packages.
- The Nix build workarounds for this specific kernel + modern Clang
  (`LLVM_IAS=0`, `DISABLE_WRAPPER=1` — see `../README.md` step 3 and
  `nix-derivated-pmos.md`) apply identically here, since mobile-nixos
  also builds with Nix.

So: **do `nix-derivated-pmos.md` first.** That Nix derivation (kernel
Image + dtb from `taoyao-s-oss`) becomes the majority of what
mobile-nixos needs too. What's left after that is mobile-nixos-specific
packaging, not more hardware reverse-engineering.

## What's actually mobile-nixos-specific

1. **`device.nix`** (mobile-nixos' rough equivalent of pmOS's
   `deviceinfo`) — device identity, boot method, partition layout,
   pointer to the kernel package.
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

- Nobody has checked whether mobile-nixos has *any* existing SM7325 or
  `lahaina`-platform device to use as a reference, the way
  `device-nothing-spacewar` was used for pmOS. Check
  `nix-community/mobile-nixos`'s device list before starting.
- Nobody has confirmed pmOS actually boots on taoyao yet. This file is
  explicitly "later" — don't start on it until that's true.
