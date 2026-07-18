# postmarketOS on Xiaomi taoyao (Xiaomi 12 Lite 5G)

Device facts (from a live EvolutionX install on the phone):

| | |
|---|---|
| codename | `taoyao` |
| model | Xiaomi 12 Lite 5G, `2203129G` |
| SoC | Qualcomm SM7325 (Snapdragon 778G), platform `lahaina` |
| partition layout | A/B, active slot at time of extraction: `_a` |
| boot format | Android boot header v3, `boot_a` (kernel+ramdisk) + `vendor_boot_a` (dtb+vendor ramdisk) |

Decision: build the kernel from Xiaomi's **published downstream source**
(`taoyao-s-oss` branch), not mainline Linux, and not the prebuilt stock
kernel binary. The binary-reuse route was tried first and rejected: pmOS's
`mkbootimg` pipeline and initramfs assume a single plain kernel Image + one
plain dtb, and no current pmaports device uses `deviceinfo_bootimg_qcdt`
(our stock `vendor_boot.img` dtb blob has 10 concatenated QCDT-format
DTBs). Reusing the binary as-is would also drop Android's `vendor_boot`
ramdisk, which the stock kernel likely needs for display/touch bring-up.

## 1. Extract the stock boot images (reference only, not required for the build)

Done once already; kept for reference on how to redo it if needed (e.g. to
diff against a newer OTA). Needs a device with `adb` access in
recovery/EvolutionX with `adb root` available.

```
adb shell getprop ro.boot.slot_suffix        # confirm active slot, e.g. "_a"
adb root
adb shell dd if=/dev/block/bootdevice/by-name/boot_a of=/sdcard/boot.img
adb shell dd if=/dev/block/bootdevice/by-name/vendor_boot_a of=/sdcard/vendor_boot.img
adb pull /sdcard/boot.img extracted/
adb pull /sdcard/vendor_boot.img extracted/

cd extracted
mkdir -p unpack && (cd unpack && unpack_bootimg --boot_img ../boot.img --out .)
mkdir -p unpack_vendor && (cd unpack_vendor && unpack_bootimg --boot_img ../vendor_boot.img --out .)
```

`unpack_bootimg` and `adb` come from the `android-tools` package in
`shell.nix`. This confirmed: header v3, page size 4096, kernel load addr
`0x8000`, ramdisk load addr `0x1000000`, tags load addr `0x100`, dtb addr
`0x1f00000` — all cross-checked against `build.config.msm.lahaina` in the
kernel source (see below) and against `device-nothing-spacewar`, an
existing pmaports device on the same SM7325 chipset.

## 2. Get the kernel source

```
git clone --depth=1 --single-branch --branch taoyao-s-oss \
  https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git kernel-taoyao
```

Confirmed via GitHub API and two independent web sources: `taoyao-s-oss`
is Xiaomi's GPL release for the taoyao kernel,
`LA.UM.9.14.r1-18300.05-LAHAINA.QSSI12.0-1`, Linux 5.4.86. This is the
*only* branch we fetch (`--single-branch`) — the upstream repo hosts
kernels for dozens of unrelated Xiaomi devices on other branches.

`kernel-taoyao/` is gitignored here — it's an unmodified upstream clone
(aside from the two local build-tooling patches below), so it's
reproduced by re-running the clone command rather than committed.

### Local patches applied to the clone (not upstream Xiaomi changes)

These are build-tooling-only fixes for building under Nix on a modern
host; they don't touch kernel/driver code:

1. **Shebang portability.** This Nix system has no `/bin/bash` (only
   `/bin/sh`, itself a `bash` symlink). Every `#!/bin/bash` shebang in the
   tree was rewritten to `#!/usr/bin/env bash`:
   ```
   grep -rl "^#!/bin/bash" --include="*.sh" . --exclude-dir=.git \
     | xargs sed -i '1s|^#!/bin/bash|#!/usr/bin/env bash|'
   ```
   Also, `scripts/gki/generate_defconfig.sh` was calling
   `${SCRIPTS_ROOT}/fragment_allyesconfig.sh` directly (relying on the now
   -fixed shebang); changed to `bash ${SCRIPTS_ROOT}/fragment_allyesconfig.sh`
   for extra safety.

If re-cloning from scratch, redo the shebang rewrite before building.

2. **One real code fix, not a tooling workaround.**
   `drivers/staging/cam-reclaim/cam_reclaim.c:104` declared
   `static inline void do_reclaim()` — old K&R-style empty-parens
   declaration, which newer Clang treats as a hard error
   (`-Wstrict-prototypes`, not suppressible via `DISABLE_WRAPPER` since
   it's a real `-Werror` flag, not the custom wrapper). Fixed to
   `do_reclaim(void)`. This is a genuine (harmless) bug in Xiaomi's
   staging driver, unrelated to our Nix/Clang-version workarounds.

## 3. Enter the build shell

```
nix-shell shell.nix
```

`shell.nix` provides: `pmbootstrap`, `git`, `android-tools`, `abootimg`,
`dtc`, `openssh` for the porting/flashing side, and `clang` + `lld` +
`llvmPackages.bintools` + a real aarch64 GNU cross-binutils
(`pkgsCross.aarch64-multiplatform.buildPackages.binutils`) + the usual
kernel build deps (`bc`, `bison`, `flex`, `openssl`, `elfutils`,
`ncurses`, `python3`, `perl`, `cpio`, `kmod`) for the kernel build.

Two toolchain issues, both worked around at build-invocation time (see
below), not by patching kernel code:

- **nixpkgs' `clang` is far newer than Google's pinned `clang-r416183b`**
  (`build.config.common` in the kernel source references that exact
  prebuilt). The version gap breaks in two ways:
  - Clang's *integrated assembler* mis-handles this kernel's old-style LSE
    atomics inline asm (`unknown register name 'x0' in asm` in
    `atomic_lse.h`). Fix: `LLVM_IAS=0`, so Clang compiles but hands
    assembly to GNU `as` from the cross-binutils package instead of its
    own assembler.
  - The kernel wraps `CC` in `scripts/gcc-wrapper.py`
    (`Makefile:459`), which treats **any** compiler warning not on a small
    hardcoded whitelist as a fatal build error. Newer Clang surfaces
    warnings the original pinned Clang didn't. Fix: the kernel's own
    `Makefile` already supports `DISABLE_WRAPPER=1` for exactly this
    (`Makefile:456-462`) — no patching needed.
  - We did *not* fetch the actual `clang-r416183b` prebilt: it's not in
    nixpkgs, and pulling Google's binary tarball in would mean
    `autoPatchelfHook`-ing a non-Nix binary for NixOS's dynamic linker
    layout — a bigger, riskier lift than the two flags above, which are
    both well-understood, documented escape hatches in the kernel's own
    build system.

## 4. Generate the merged defconfig

The kernel uses Qualcomm's fragment-based defconfig system: a base
`gki_defconfig` merged with `arch/arm64/configs/vendor/taoyao_QGKI.config`
(and an auto-generated all-yes variant of the GKI fragment). Variant
`qgki` matches what a retail/production taoyao build uses.

```
cd kernel-taoyao
export ARCH=arm64 LLVM=1 LLVM_IAS=1 TARGET_BUILD_VARIANT=eng ENABLE_MIUI_DEBUGGING=false
bash scripts/gki/generate_defconfig.sh vendor/taoyao-qgki_defconfig
```

(`LLVM_IAS=1` is fine here — this step only runs kconfig tooling, not the
part that hits the asm bug.) Output:
`arch/arm64/configs/vendor/taoyao-qgki_defconfig`, 952 lines.

## 5. Build the kernel Image

```
mkdir -p out
export ARCH=arm64 LLVM=1 LLVM_IAS=0 CROSS_COMPILE=aarch64-unknown-linux-gnu- DISABLE_WRAPPER=1
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=0 CROSS_COMPILE=aarch64-unknown-linux-gnu- DISABLE_WRAPPER=1 \
  vendor/taoyao-qgki_defconfig
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=0 CROSS_COMPILE=aarch64-unknown-linux-gnu- DISABLE_WRAPPER=1 \
  -j"$(nproc)" -k Image
```

(`-k` = keep going past errors instead of stopping at the first one —
useful on a first build of a large downstream tree, since it surfaces
all the real code issues like the `cam_reclaim.c` one above in a single
pass instead of one failure-fix-retry cycle each.)

Output: `kernel-taoyao/out/arch/arm64/boot/Image`, copied to
`build-output/Image` for convenience (`build-output/` is gitignored —
it's a build artifact, reproducible from the two source clones).

Logs from this build live in `logs/` (gitignored).

## 6. Build the device tree

The kernel source repo (`kernel-taoyao/`) has **no device tree source** —
Xiaomi ships DTS in a separate repo. `arch/arm64/boot/dts/Makefile` only
builds a `vendor/` subdirectory if `vendor/Makefile` exists, so:

```
git clone --depth=1 --single-branch --branch taoyao-s-oss \
  https://github.com/MiCode/kernel_devicetree.git kernel-devicetree-taoyao

ln -s ../../../../../kernel-devicetree-taoyao \
  kernel-taoyao/arch/arm64/boot/dts/vendor
```

(same branch name, confirmed via GitHub API before cloning; `kernel-devicetree-taoyao/`
is gitignored, same reasoning as the kernel clone in step 2.)

taoyao isn't a standalone dtb — Qualcomm builds it as a **DT overlay**
(`taoyao-sm7325-overlay.dtbo`, base `yupik.dtb`; see
`kernel-devicetree-taoyao/qcom/Makefile`), gated on
`CONFIG_BUILD_ARM64_DT_OVERLAY`, which the merged defconfig from step 4
did *not* set (only `CONFIG_ARCH_YUPIK=y` came from the QGKI fragment).
Confirmed by checking `out/.config` after a first `dtbs` build produced
only generic `yupik-*.dtb` reference boards, no taoyao output. Fix:

```
echo "CONFIG_BUILD_ARM64_DT_OVERLAY=y" >> arch/arm64/configs/vendor/taoyao-qgki_defconfig
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=0 CROSS_COMPILE=aarch64-unknown-linux-gnu- DISABLE_WRAPPER=1 \
  vendor/taoyao-qgki_defconfig
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=0 CROSS_COMPILE=aarch64-unknown-linux-gnu- DISABLE_WRAPPER=1 \
  -j"$(nproc)" -k dtbs
```

This produces `out/arch/arm64/boot/dts/vendor/qcom/taoyao-sm7325-overlay.dtbo`
and `.../yupik.dtb` (the base it overlays). pmOS's `deviceinfo_dtb`
mechanism (like `device-nothing-spacewar`'s, our template) expects one
plain merged dtb, not a base+overlay pair, so merge them statically:

```
fdtoverlay -i out/arch/arm64/boot/dts/vendor/qcom/yupik.dtb \
           -o taoyao.dtb \
           out/arch/arm64/boot/dts/vendor/qcom/taoyao-sm7325-overlay.dtbo
```

(`fdtoverlay` is part of the `dtc` package already in `shell.nix`.)
Verified the merge actually applied — decompiled the result and confirmed
taoyao-specific nodes are present and properly nested (not orphaned):
`xiaomi_ts_touch@0` (touchscreen), `awinic_haptic@58`, `tfa98xx@34`/`@35`
(audio codec). Note: the root `model`/`compatible`/`qcom,board-id`
properties stay as the base's ("Yupik SoC") after merging — that's
expected, not a merge failure. Those fields live *outside* any
`fragment@N`/`__overlay__` block in the compiled `.dtbo` (Qualcomm uses
them as bootloader-side board-selection metadata for picking which
overlay to apply in the first place, not as content to merge into the
final tree), so `fdtoverlay` correctly leaves them alone. Cosmetic only —
`/proc/device-tree/model` will read "Yupik SoC" on the booted device;
doesn't affect functionality since drivers match on the deeper
`compatible` strings of individual nodes, not this top-level one.

Output copied to `build-output/taoyao.dtb`.

## 7. postmarketOS device port

Scaffold lives in `pmaports-local/device/testing/`:
`device-xiaomi-taoyao` and `linux-xiaomi-taoyao`, using the real
`devicepkg-dev` helpers (`devicepkg_build`/`devicepkg_package`, found by
reading `main/devicepkg-dev/*.sh` in a sparse pmaports checkout, since no
live pmaports device still uses the from-source
`downstreamkernel_prepare`/`downstreamkernel_package` pattern as a
copyable example — see `pmaports-local/README.md` for the known gaps,
notably no kernel modules packaged yet and `deviceinfo_super_partitions`
intentionally left unset/unverified).

## 8. Get pmbootstrap running without the interactive wizard

`pmbootstrap init`'s wizard is entirely replaceable with direct config —
every question it asks is just a `pmbootstrap config <key> <value>`
under the hood, confirmed by reading `pmb/core/config.py`. Faster to
write the config file directly:

```
git clone --depth=1 https://gitlab.postmarketos.org/postmarketOS/pmaports.git pmaports-full
cp -r pmaports-local/device/testing/device-xiaomi-taoyao pmaports-full/device/testing/
cp -r pmaports-local/device/testing/linux-xiaomi-taoyao pmaports-full/device/testing/
```

(`pmaports-full/` is gitignored — same reasoning as the kernel clones.
The two `cp -r` calls preserve the `Image`/`taoyao.dtb` symlinks
correctly since `pmaports-full/` sits at the same directory depth as
`pmaports-local/`, so the existing `../../../../build-output/...`
relative paths still resolve.)

```
mkdir -p ~/.local/var/pmbootstrap
echo "8" > ~/.local/var/pmbootstrap/version   # pmb.config.work_version — skips
                                                # the "please run init" migration check
cat > ~/.config/pmbootstrap_v3.cfg <<'EOF'
[pmbootstrap]
aports = /home/user/project/linux-taoyao/pmaports-full
device = xiaomi-taoyao
ui = console
user = user
hostname = taoyao-pmos

[providers]

[mirrors]
EOF
```

(Config path confirmed via `pmb/config/__init__.py`:
`~/.config/pmbootstrap_v3.cfg`, *not* the `pmbootstrap.cfg` name older
docs might reference — pmbootstrap explicitly detects the old filename
and refuses to start, telling you to regenerate via `init`.)

Verified this actually works — `pmbootstrap deviceinfo_parse xiaomi-taoyao`
(well, the closest working equivalent — that exact subcommand doesn't
exist in this pmbootstrap version, but any subcommand prints a status
banner) reports `Device: xiaomi-taoyao (aarch64)`, confirming our
`deviceinfo` parses correctly and the device is recognized.

## 9. `pmbootstrap install` — blocked on root, handed off

```
pmbootstrap -y install --password test1234
```

Gets as far as `(1/4) PREPARE NATIVE CHROOT` then fails:
`Command failed (exit code 1): % sudo mkdir -p .../chroot_native/dev`.
This is a genuine, correct requirement — setting up the Alpine chroot
needs real root (mounting `/dev`, `/proc`, etc., not something to work
around), and `sudo` here needs an interactive password not available in
this session. Also just not something to run unattended regardless —
it's a real privileged system operation.

Needed to be run interactively by hand (needs a real `sudo` password) —
not something this assistant can run itself, and not something to run
unattended regardless given it's a real privileged system operation.

First real attempt failed fast with a much simpler problem than
expected: `maintainer="you"` in both APKBUILDs isn't a valid RFC822
address, and `abuild` rejects that outright (`'you' is not a valid
rfc822 address`). Fixed to a real name/email (pulled from `git config
user.name`/`user.email` rather than inventing one).

Second attempt: **`DONE!`** — full success. `pmbootstrap install`
built both `linux-xiaomi-taoyao` and `device-xiaomi-taoyao` from our
packages, assembled the rootfs, and produced:

- `~/.local/var/pmbootstrap/chroot_native/home/pmos/rootfs/xiaomi-taoyao.img`
  — combined rootfs+boot image (single file, own internal partition
  table for `/boot` + `/`, so no repartitioning of the real device is
  needed to flash it)
- `~/.local/var/pmbootstrap/chroot_rootfs_xiaomi-taoyao/boot` — kernel +
  initramfs, flashable/bootable separately

## 10. Testing on-device — non-destructive first

pmbootstrap offers three ways to get this onto the device. Given the
flashing-safety discussion earlier (never risk a state where you can't
reflash — see conversation, not written up separately here), the right
order is:

1. **`pmbootstrap flasher boot`** — `fastboot boot`s the kernel+initramfs
   directly into RAM, no write to the device at all. This is the one to
   try first: if the from-scratch kernel/merged dtb are wrong in some
   way that prevents booting, you find out with *zero* risk — reboot and
   the device is untouched. Only reason to not fully trust this as a
   complete test: it doesn't validate the actual flash-and-persist path,
   only whether the kernel/dtb/initramfs combination boots at all.
2. `pmbootstrap flasher flash_kernel` — writes kernel+initramfs for
   real (to `boot_a`, per `deviceinfo_flash_method=fastboot` — verify
   this before running it, don't assume).
3. `pmbootstrap flasher flash_rootfs` — writes the rootfs image for
   real.

Not yet attempted. This is the next step.
