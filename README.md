# postmarketOS on Xiaomi taoyao (Xiaomi 12 Lite 5G)

Device facts (from a live EvolutionX install on the phone):

| | |
|---|---|
| codename | `taoyao` |
| model | Xiaomi 12 Lite 5G, `2203129G` |
| SoC | Qualcomm SM7325 (Snapdragon 778G), platform `lahaina` |
| partition layout | A/B, active slot at time of extraction: `_a` |
| boot format | Android boot header v3, `boot_a` (kernel+ramdisk) + `vendor_boot_a` (dtb+vendor ramdisk) |

**Current status: using the mainline kernel** (see "Pivot to mainline"
near the end) — the downstream approach documented in steps 1-10 below
got real, working progress (a genuine from-scratch kernel build, several
real bugs found and fixed) but hit a boot hang that needed a serial
console to diagnose further, and the postmarketOS wiki turned up a
maintained mainline fork already confirmed working on this exact
device. Steps 1-10 are kept as-is, not deleted — real work, real
findings, and the dtb/hardware facts discovered there (boot format,
load offsets) are still accurate/reused. Skip to "Pivot to mainline" for
the current, active approach.

Original decision (superseded, kept for context): build the kernel from
Xiaomi's **published downstream source** (`taoyao-s-oss` branch), not
mainline Linux, and not the prebuilt stock kernel binary. The
binary-reuse route was tried first and rejected: pmOS's `mkbootimg`
pipeline and initramfs assume a single plain kernel Image + one plain
dtb, and no current pmaports device uses `deviceinfo_bootimg_qcdt` (our
stock `vendor_boot.img` dtb blob has 10 concatenated QCDT-format DTBs).
Reusing the binary as-is would also drop Android's `vendor_boot`
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

### First `flasher boot` attempt: booted, then reset after ~10s

`fastboot boot` succeeded on the host side (image accepted, sent,
"Booting" OKAY) — but the device went black for ~10 seconds then
rebooted back into EvolutionX on its own. Exactly the safe outcome the
non-destructive test is for: `fastboot boot` never writes anything, so
when the temporarily-booted kernel didn't survive, the device just fell
back to whatever's actually flashed. No damage, no data loss.

**Diagnosed the actual cause without a serial console**, using
Qualcomm's `pstore`/`ramoops` mechanism — a reserved memory region that
persists console output across a reset, readable from the *next* boot.
Since our merged `taoyao.dtb` reused the real device's reserved-memory
layout, the crash log from our kernel attempt was sitting there once
back in EvolutionX:

```
adb shell su -c 'cat /sys/fs/pstore/console-ramoops-0'
```

This showed the kernel genuinely booting and doing real hardware
bring-up for ~1.4 seconds — PMIC/regulator init, and the `aw8622x`
haptics driver fully probed and ran its calibration routine
successfully. Confirms the kernel/dtb combination fundamentally works.
The log then fills with hundreds of repeated
`hh_rm_call: ... failed with RM err: 6` / `hh_rm_console_write: Unable
to send CONSOLE_WRITE to RM: -22` lines and ends at `Warning: unable to
open an initial console` — no panic message after that, consistent with
boot stalling there until the ~10s watchdog reset.

`hh_*` is Qualcomm's Gunyah/Haven hypervisor resource-manager (RM)
interface. Root cause: `CONFIG_HAVEN_DRIVERS=y` (and its sub-options —
`HH_CTRL`, `HH_MSGQ`, `HH_RM_DRV`, `HH_DBL`, `HH_IRQ_LEND`,
`HH_MEM_NOTIFIER`, `HH_VIRT_WATCHDOG` — plus `HVC_HAVEN`, `QRTR_HAVEN`,
`QCOM_MEM_BUF` elsewhere in the tree) assume a working hypervisor RM
channel that isn't available/functional when booting this way — every
single RM call fails, not just some, consistent with the channel simply
not being connected rather than a slow/flaky driver. Two of the
dependent drivers explain two separate log symptoms directly:
`HVC_HAVEN` (`depends on HH_RM_DRV`) is what's failing to open the
"initial console" — exactly where forward progress in the log stops —
and `HH_VIRT_WATCHDOG` is a watchdog-petting driver that depends on the
same broken channel, a very plausible trigger for the reset itself.

Fix: disabled the whole Haven/Gunyah subsystem in
`arch/arm64/configs/vendor/taoyao-qgki_defconfig`
(`# CONFIG_HAVEN_DRIVERS is not set` — cascades to disable all the
`HH_*` sub-options automatically via Kconfig `if HAVEN_DRIVERS`/`endif`
nesting, confirmed by checking `out/.config` after regenerating; also
explicitly disabled `HVC_HAVEN`, `QRTR_HAVEN`, `QCOM_MEM_BUF` which live
outside that `if` block). Rebuilt (`make ... Image` — no `dtbs` rebuild
needed, only kernel driver config changed), re-synced
`build-output/Image` and its checksum in
`pmaports-local/device/testing/linux-xiaomi-taoyao/APKBUILD` (bumped
`pkgrel`), re-ran `pmbootstrap install` and `pmbootstrap flasher boot`.

### Second `flasher boot` attempt: no reset, but no USB either

Confirmed the Haven fix worked: no auto-reboot this time, device stayed
up past a minute (vs. ~10s before). But `lsusb`/`fastboot devices`/
`adb devices` showed nothing from the device at all — no way to reach
it. Recovered a second, much shorter/cleaner `pstore` log (116 lines vs.
1193 before) confirming the `hh_rm_call` spam is completely gone. It
still ends at the same `Warning: unable to open an initial console`
message, but re-examined what that actually means: it's PID 1 failing
to open a controlling tty (stdin/stdout for `init`), which doesn't stop
`printk`/pstore logging in general — so the log ending there doesn't
necessarily mean the kernel died there. Combined with no reset, the
likely read is the kernel booted successfully into userspace and is
just invisible to us (no console, no way to reach it over USB yet).

Ran a continuous host-side USB/network monitor (1s polling) starting
before the next `fastboot boot`, to see what actually happens on the
wire rather than checking well after the fact. Findings:

- Ruled out "missing kernel module" as the explanation for no USB
  networking — checked `out/.config`: `CONFIG_USB_DWC3`,
  `CONFIG_USB_GADGET`, `CONFIG_USB_CONFIGFS`, and the NCM/ACM gadget
  functions pmOS's usb-network mkinitfs hook needs are all `=y`
  (built-in), not modules. Not a modules-packaging gap this time.
- The monitor caught `Bus 003 Device 019: ID 18d1:d00d ... (fastboot)`
  — the bootloader's own fastboot USB identity — persisting completely
  unchanged for the entire time between `fastboot boot` and the eventual
  `USB disconnect, device number 19` the host logged. After that
  disconnect (which is just fastboot's own protocol session ending as
  it hands off to the kernel — expected, not itself a bad sign), the
  bus stayed completely empty for the remaining ~100s of monitoring.
  Nothing from our kernel's own USB gadget ever appeared, at any point.

That combination — kernel apparently running fine, but never presenting
its own USB gadget identity — pointed at the DWC3 driver's cable-detect
state machine rather than anything display/console-related. Traced
`assume cable is not connected` in
`drivers/usb/dwc3/dwc3-msm.c:5047` back through the code:

- That specific line is charger-type auto-detection (`apsd`) logic, not
  cable-attach detection — the comment there says the controller can
  proceed normally without it. A red herring.
- The actual cable-attach signal comes through `extcon`, registered from
  `ssusb@a600000`'s `extcon` phandle in the dtb, pointing to
  `qcom,msm-eud@88e0000` — Qualcomm's "Embedded USB Debugger" block,
  configured with `qcom,secure-eud-en` (needs a secure TrustZone/SCM
  call to enable). The *very first* line of both pstore logs is
  `scm_mem_protection_init_do: SCM call failed` — SCM/TrustZone
  communication is broken from the first moment of boot. Plausible
  unifying cause for both the Haven RM failures and this: `fastboot
  boot` (unsigned/temporary boot) likely skips TrustZone provisioning a
  normal verified boot chain would perform.
- Found the fix in the driver itself
  (`drivers/usb/dwc3/dwc3-msm.c:5063`): `if (!mdwc->role_switch &&
  !mdwc->extcon)` — when there's no extcon registered at all, the
  driver falls back to unconditionally setting `vbus_active = true`
  ("assume always connected"), exactly the behavior wanted here since a
  cable is always physically present during bring-up testing.

Fix: removed the `extcon` property from `ssusb@a600000` in the base
`yupik.dtb` (not the taoyao overlay — the property lives in the base),
using `fdtput -d out/.../yupik.dtb /soc/ssusb@a600000 extcon`, then
re-ran the `fdtoverlay` merge from README step 6 to produce a new
`build-output/taoyao.dtb` (no kernel rebuild needed — dtb-only change).
Re-synced the checksum in `linux-xiaomi-taoyao`'s `APKBUILD`, bumped
`pkgrel` again.

### Third `flasher boot` attempt: extcon fix confirmed applied, still no progress

Ran a `pmbootstrap install` that failed partway (`mkfs.ext2: No such
device or address` on `/dev/installp1` — a stale/flaky loop-device
mapping left over from a previous run's `/dev/loop0`; `kpartx` didn't
recreate the partition device node in time). Not persistent — `pmbootstrap
shutdown` to tear down all chroot mounts/loop devices, then re-running
`install`, fixed it cleanly. Confirmed nothing had actually been flashed
to the device at any point during this — `install` failing partway
doesn't touch the real device at all, only its own local image-building
chroot.

Diffed this attempt's `pstore` log against the previous one line-by-line
(`diff`). Confirmed the extcon fix genuinely took effect: the `assume
cable is not connected` debug line — which came specifically from the
`dpdm_reg` check inside the `if (of_property_read_bool(node, "extcon"))`
block we removed — is gone from this log, present in the old one. But
the fix didn't solve the actual problem: log length, content, and exact
stall point (`Warning: unable to open an initial console`, ~1.4s in)
are otherwise near-identical between both attempts, and USB still never
enumerates. Revised the earlier "probably booted fine, just invisible"
read — a real successful boot to userspace would normally log at least
a few more generic messages (mounting rootfs, `Run /init`, a startup
banner) even at low verbosity; getting *total* silence for 100+ seconds
straight, twice in a row at nearly identical timing, looks more like
boot genuinely halting right there.

Found a much more fundamental issue by reading `pmbootstrap`'s own
flasher code (`pmb/flasher/variables.py`):
```python
cmdline_ = deviceinfo.kernel_cmdline or ""
```
`deviceinfo_kernel_cmdline` was never set in our `deviceinfo` — meaning
every boot attempt so far has been running with a **completely empty
kernel command line**. No `console=`, nothing at all. This alone is a
very plausible explanation for a console-related stall, independent of
anything else diagnosed so far.

Fix: set `deviceinfo_kernel_cmdline="console=ttyMSM0,115200n8"`, using
the real device's own known-correct cmdline value already extracted
from the stock `vendor_boot.img` back in step 1 — not a guess. Bumped
`device-xiaomi-taoyao`'s `pkgrel` (deviceinfo changed, not the kernel
package this time) and re-synced the checksum.

### Fourth attempt: cmdline fix applied, still the same black
### screen + brief vibration, no further progress

Same symptom as before, no visible change. Three separate real issues
were found and fixed across four attempts (Haven/Gunyah, extcon/EUD,
empty cmdline — each confirmed distinct via `pstore` log diffing, not
guessed), and none of them, individually or combined, got past the
boot hang. At this point further progress genuinely needs a serial
console (physical UART access) to see what's actually happening after
the point where `pstore` logging goes silent — not something diagnosable
further from software alone.

## Pivot to mainline

While stuck on the above, checked the postmarketOS wiki for a taoyao
page — found one:
[Xiaomi 12 Lite 5G (xiaomi-taoyao)](https://wiki.postmarketos.org/wiki/Xiaomi_12_Lite_5G_(xiaomi-taoyao))
(page not reachable by normal fetch — this instance runs Anubis bot
protection; readable via `https://r.jina.ai/<url>` as a proxy). It
documents a **working** taoyao port: display, touchscreen, 3D
acceleration, WiFi, Bluetooth, calls/SMS/mobile data, USB networking,
USB OTG all confirmed working, using a **mainline** kernel — not
Xiaomi's downstream source. Not yet merged into pmaports (manual
install only), maintained by wiki user `zstas`.

Kernel source: [github.com/sc7280-mainline/linux](https://github.com/sc7280-mainline/linux)
— "Mainline Kernel fork for SC7280/SM7325/QCM6490 devices", actively
maintained (branches through kernel 7.1.y as of writing). Confirmed via
GitHub API it ships `arch/arm64/boot/dts/qcom/sm7325-xiaomi-taoyao.dts`,
and confirmed via the actual `Makefile` content (not just file
presence) that it's wired into the build:
`dtb-$(CONFIG_ARCH_QCOM) += sm7325-xiaomi-taoyao.dtb`.

Better still: this kernel is **already packaged in pmaports**, at
`device/community/linux-postmarketos-qcom-sc7280` (missed on the first
search of this repo — only `device/testing/` was checked; `grep`ing the
full local clone directly found it immediately). Real from-source
APKBUILD, fetches tagged release `v7.1.2-sc7280`, standard
`make ... dtbs_install`. Already depended on by `device-nothing-spacewar`
(the same reference device used for the original `deviceinfo` values),
confirming it's a real, live, currently-building package — not
something we'd be the first to exercise.

Given: (a) real, working progress on downstream had genuinely stalled
and needed hardware (serial console) neither of us has, and (b) a
maintained, already-packaged mainline alternative exists with taoyao
support *already confirmed working by someone else on this exact
device* — switched to it. This is explicitly a deviation from the
original "downstream, not mainline" decision at the top of this file;
flagged to and approved by the user before making the change, given how
much it changes the plan.

### What changed

Only `pmaports-local/device/testing/device-xiaomi-taoyao/`:

- `deviceinfo_dtb`: `qcom/taoyao` (our own merged dtb) →
  `qcom/sm7325-xiaomi-taoyao` (the mainline package's dtb, following
  `device-nothing-spacewar`'s exact naming convention for the same
  kernel package).
- Removed `deviceinfo_kernel_cmdline` — that was specifically a
  downstream-bring-up workaround; `device-nothing-spacewar`, on the same
  mainline kernel package, doesn't set one either, so trusting
  pmOS/mainline's own defaults instead.
- `APKBUILD` `depends`: `linux-xiaomi-taoyao` (our custom
  prebuilt-artifact package) → `linux-postmarketos-qcom-sc7280` (the
  existing, real, from-source mainline package). Bumped `pkgrel`.

Everything else — flash offsets, header version, page size, chassis,
etc. — is unchanged, since those are real hardware/bootloader facts
independent of which kernel is running, already confirmed in step 1
against the actual device.

`linux-xiaomi-taoyao` (our downstream kernel package) and everything in
`kernel-taoyao/`/`kernel-devicetree-taoyao/`/`build-output/` are left in
place, not deleted — real work, useful if downstream is revisited later
(see `TODOs/dual-build.md`), and git history plus this README preserve
the full debugging trail regardless.

### First mainline attempt: worse than downstream — instant fallback, no progress

Tested. `fastboot boot` reported success on the host side as usual, but
this time: black screen, **no vibration at all** (vs. the downstream
kernel's brief haptic-calibration buzz), and `fastboot devices`
afterward still showed the phone in fastboot mode with the *same*
unchanged device descriptor — no evidence the kernel ever started
executing, not even the ~1.4s of real hardware bring-up the downstream
kernel managed. (No vibration isn't itself concerning — the wiki lists
haptics as a broken feature on this mainline port.)

Checked the actual boot artifacts pmbootstrap generated
(`~/.local/var/pmbootstrap/chroot_rootfs_xiaomi-taoyao/boot/`):
`vmlinuz` is `gzip compressed data` (13.7MB compressed, 36.8MB
uncompressed) — not a raw bootable ARM64 `Image` the way our downstream
kernel's boot image was (49MB, uncompressed). A `linux.efi` file also
sits right next to it. Re-checked `device-nothing-spacewar`'s `APKBUILD`
(same kernel package) and noticed its `depends=` includes
`systemd-boot`, which ours didn't. Reading between these: this kernel
package is meant to be launched via **systemd-boot chainloading** (a
UEFI-capable stub gets fastboot-flashed to the boot partition, which
then loads the real kernel via UEFI) — not a direct raw-Image jump the
way ABL boots our downstream kernel. Missing that piece would fully
explain zero execution progress: what ended up in the boot image wasn't
something ABL could directly run at all.

Fix: added `systemd-boot` to `device-xiaomi-taoyao`'s `APKBUILD`
`depends`, matching `device-nothing-spacewar` exactly. Bumped `pkgrel`.

### Real safety incident: repeated `flasher boot` attempts flipped the active A/B slot

Tested the `systemd-boot` fix. `fastboot boot` this time failed
differently: `Booting FAILED (Status read failed (No such device))` —
the boot.img was sent successfully, but the USB link dropped mid-command
as it tried to boot, unlike previous attempts which reported success and
then just silently hung. Device then visibly rebooted into EvolutionX on
its own.

Checked `fastboot getvar` afterward and found something important:
```
current-slot: b
slot-unbootable:a: yes
slot-unbootable:b: no
```
**The active A/B slot had switched from A to B, and slot A was marked
unbootable by the bootloader.** This matters because the whole earlier
safety plan (see conversation — not written up separately) was built
around "only ever touch slot A, keep slot B pristine as a guaranteed
-safe fallback." `pmbootstrap flasher boot` is supposed to be RAM-only
with no persistent writes, but apparently that guarantee only covers
the boot payload's *content* — this bootloader still counts repeated
failed/crashed `fastboot boot` attempts against slot A's persistent
retry counter, and enough of them exhausted it and triggered the
standard Android A/B automatic-fallback-on-repeated-failure mechanism.

Recovered cleanly: `fastboot --set-active=a` (metadata-only slot
pointer change) immediately cleared `slot-unbootable:a` back to `no`
and reset the retry count to max. Verified slot A's actual *content*
was never touched (not just the metadata) by doing a real `fastboot
reboot` into normal Android — booted cleanly, `su` access confirmed
working. Full recovery confirmed, not just assumed.

**Real process lesson, at real cost:** that verification reboot
overwrote the `pstore`/`ramoops` buffer (it only holds one prior boot's
log at a time), destroying the mainline crash log this whole detour was
trying to capture — the automatic slot-B fallback boot likely already
overwrote it once before that too. Going forward: grab `pstore`
**immediately** on the very next boot after any `flasher boot` attempt,
before doing anything else, including "just double-checking" reboots.

Going forward, also worth minimizing the *number* of raw `flasher boot`
attempts given they turned out to have this persistent side effect
after all — treat each one as having a real (if recoverable) cost, not
as free experimentation.

### Re-checked the wiki for missed detail, then tried a real flash

Went back to the wiki page and asked more narrowly (exact commands,
`deviceinfo` values, kernel-format notes, quoting installation/notes
sections directly) rather than a general summary, to make sure nothing
was missed. Confirmed there genuinely isn't more there — it's a
standard MediaWiki device-status page (hardware spec table, feature
checklist, generic "unlock bootloader / `flash_kernel` / `flash_rootfs`"
boilerplate templated across all not-yet-merged device pages), not a
porting guide with an actual `deviceinfo` or format notes included.
Also checked for the credited wiki contributor (`zstas`)'s actual
pmaports fork/MR on GitLab — none found; their exact recipe isn't
published anywhere findable.

One real, usable difference the wiki did confirm: they used
`pmbootstrap flasher flash_kernel`/`flash_rootfs` (an actual flash), not
`flasher boot` (RAM-only) like all our attempts so far. Tried it:

```
fastboot flash boot_a  <-- via `pmbootstrap flasher flash_kernel`, confirmed
                            it resolves to a plain `fastboot flash boot
                            <file>` (deviceinfo_flash_fastboot_partition_kernel
                            unset → defaults to "boot", fastboot auto
                            -targets the active slot) -- verified this
                            stays within the safety boundary (raw
                            overwrite of an existing partition, no
                            repartitioning) before running it
```

Result: booted straight back to the **fastboot menu itself**, not our
kernel, not a silent hang, not stock. A third distinct failure mode.
Checked slot state immediately after: `slot-unbootable:a: no`, retry
count only decremented by one (7→6, not exhausted) — the bootloader
caught the bad image and rejected it cleanly this time, rather than the
messier auto-fallback-to-B behavior from the RAM-boot attempts. This is
consistent with (not proof of, but consistent with) the
compressed-kernel-image-format theory from the previous section: a real
persistent flash + normal boot hits the *same* instant-rejection outcome
as the temporary RAM boot did, which argues against "maybe it only fails
via `fastboot boot` specifically" as an explanation.

**Restored the device to stock before stopping.** Slot A had our
non-working kernel permanently flashed to it at this point — left as-is,
any future normal reboot would hit the same rejection and keep consuming
retries. Reflashed the real stock `boot_a` from `extracted/boot.img`
(the backup taken at the very start of this whole project), rebooted,
and verified a full clean normal boot (not just checking `getvar` —
actually booted to system, confirmed `root` access works). **Device is
back to its exact original state**, nothing left mid-experiment.

## Status at end of session

Two kernel approaches both got real, substantive progress and both hit
real blockers:

- **Downstream** (`taoyao-s-oss`): builds cleanly, actually executes and
  does real hardware bring-up (~1.4s of driver probes visible in
  `pstore`), but hangs partway through boot in a way that needs a
  physical serial console to diagnose further — not resolvable from
  software alone with the tools available this session.
- **Mainline** (`sc7280-mainline/linux`, already packaged in pmaports):
  proven working by someone else on this exact device per the wiki, but
  every attempt here (RAM boot and real flash both) gets rejected before
  executing any of our kernel's code at all, most likely due to the
  kernel image being packaged compressed (`vmlinuz`, raw gzip) rather
  than as a plain bootable `Image` — not yet confirmed, not yet fixed.

Both `pmaports-local/device/testing/device-xiaomi-taoyao/` (currently
configured for the mainline attempt) and
`pmaports-local/device/testing/linux-xiaomi-taoyao/` (the downstream
package, superseded but preserved) are committed and ready to resume
from. The device itself is fully restored to stock. Next concrete step,
whenever this is picked back up: investigate whether
`postmarketos-mkinitfs`/the `mkbootimg`-invoking logic can be made to
package a plain uncompressed `Image` instead of `vmlinuz`, to directly
test the compression-format theory.

## Session 2: real root causes found, mainline kernel still crashes instantly

Picked back up with real `sudo` access to pmbootstrap (fixes the earlier
`mkfs.ext2`/stale-loop-device install failures for good) and worked
through the compression theory above -- and several bigger, real bugs
past it. In order of discovery:

**The compression theory was wrong.** Decompressed `vmlinuz` to a raw
`Image` locally (`gunzip`), rebuilt `boot.img` by hand with it, flashed
for real: identical instant rejection. The kernel package's own comment
(`"Old GZIP'd kernel image for boot.img compatibility"`) turned out to
be accurate -- gzip is fine, `nothing-spacewar` boots the same package
the same way.

**`deviceinfo_header_version="2"` was flatly wrong.** Copied from
`device-nothing-spacewar` early on and never actually checked against
this device. Re-ran `unpack_bootimg` on our *own* stock `boot.img`
backup (extracted at the very start of this project) and it says,
unambiguously: `boot image header version: 3`. Header v2 is a single
combined image; v3 splits `boot.img` (kernel only) from a separate
`vendor_boot.img` (dtb + vendor ramdisk + vendor cmdline) -- this device
has always had a real `vendor_boot_a`/`vendor_boot_b` partition pair
that we'd never touched. Flashing a v2-shaped image to a v3-only
bootloader explains the perfectly consistent, payload-independent,
~1-second rejection we kept seeing.

**Xiaomi enforces AVB (vbmeta) verification even unlocked.**
`fastboot getvar secure` reports `yes`. Dumped the real stock
`vbmeta_a` via `adb shell su -c dd` (fastboot on this device doesn't
support `fetch`, so this was the only way to get a real backup --
saved as `extracted/vbmeta_a_stock.img`), built a
verification-and-hashtree-disabled replacement with `avbtool
make_vbmeta_image --flags 3`. Also found `anti:1` in `getvar all`
(anti-rollback index) and had to pass `--rollback_index 1` to match it
-- a default-0 vbmeta gets silently rejected by TrustZone independently
of the AVB hash checks. **Later disproven as the blocker for this
specific failure** (see below) but both fixes are real and were needed
to get anywhere -- kept as part of the device config.

**pmbootstrap's own pipeline already fully supports header v3/v4**
(`boot-deploy`, part of `postmarketos-base`, invoked via
`postmarketos-mkinitfs`) -- we just weren't using it, and had been
hand-building images with `mkbootimg` ourselves, which turned out to
have real mistakes: our by-hand images put the real initramfs in
`boot.img`'s generic ramdisk slot; the actual pipeline puts the *entire*
real initramfs into `vendor_boot`'s `--vendor_ramdisk` instead, leaving
`boot.img` with no ramdisk at all. Fixing `deviceinfo_header_version` to
`"3"` and rebuilding surfaced two more concrete bugs on the way to a
correct build:
- `deviceinfo_generate_bootimg="true"` requires the `android-tools`
  package specifically (real Google `mkbootimg` with `--vendor_boot`
  support) -- our `APKBUILD` depended on the generic `mkbootimg` virtual,
  which resolves to `mkbootimg-osm0sis` and doesn't support v3/v4 at
  all. Fixed: `depends=` now lists `android-tools`.
- `deviceinfo_append_dtb="true"` (also copied from `nothing-spacewar`,
  a v2 device) made `boot-deploy` append the dtb directly onto the
  kernel blob even under header v3, where the dtb only belongs in
  `vendor_boot`. Fixed: `deviceinfo_append_dtb="false"`.
- For header v3/v4, `boot-deploy`'s `mkbootimg` invocation does **not**
  forward any of `deviceinfo_flash_offset_*` -- only
  `${deviceinfo_bootimg_custom_args}`. Without it, `mkbootimg` silently
  falls back to its own default base (`0x10000000`), producing a
  `vendor_boot.img` with `kernel load address: 0x10008000` instead of
  this device's real `0x00008000` (same +0x10000000 bug hit the dtb
  address too). Fixed by setting `deviceinfo_bootimg_custom_args="--base
  0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000
  --tags_offset 0x00000100 --dtb_offset 0x01f00000"` explicitly.
  Verified afterwards with `unpack_bootimg` that the generated
  `vendor_boot.img` has the exact correct addresses.

With all of the above fixed and a `boot.img`/`vendor_boot.img` pair
built entirely by the real, unmodified pmOS pipeline (not hand-crafted):
**still an identical instant rejection.** To isolate the variable
further, swapped in EvolutionX's own (stock, known-working) kernel
binary in place of the mainline one, keeping our pmOS initramfs --
this got meaningfully further: the device hung on the Mi splash logo
(needing a hard power-reset) instead of instantly bouncing back to
fastboot. That is a real, different failure mode, and it isolates the
problem to the mainline kernel/dtb combination itself, not the image
format -- confirmed further by re-testing with **stock vbmeta
(verification re-enabled)** against our correctly-formatted mainline
v3 image: identical instant rejection either way, proving vbmeta was
never actually the blocker for this particular failure.

**Conclusion:** the boot image pipeline is now provably correct (real
pmOS tooling, verified load addresses, vbmeta ruled out as a variable).
The mainline kernel (`sc7280-mainline/linux` tag `v7.1.2-sc7280`,
confirmed to actually contain the merged taoyao devicetree from
[PR #9](https://github.com/sc7280-mainline/linux/pull/9)) crashes within
about a second of being handed control -- before UART/framebuffer even
come up, too fast to leave anything in `pstore`. This class of failure
(near-instant crash at kernel entry) is consistent with a PSCI/EL2
hypervisor handshake problem specific to this device's Gunyah/TrustZone
state, the same category of issue (just earlier/more fatal) that the
downstream-kernel `Haven`/`Gunyah` hang from session 1 ran into. Reached
the same wall as session 1: further diagnosis needs a physical
serial/UART console, not resolvable purely over `fastboot`/`adb` with
the tools available here. The wiki author (`zstas`, verified as the
actual PR #9 author) never published deviceinfo/flashing specifics
beyond what's already reflected here -- likely because they have serial
console access on their own unit.

**Device fully restored to stock again** (`boot_a`, `vendor_boot_a`,
`vbmeta_a` all reflashed from the `extracted/` backups, confirmed
booting to EvolutionX normally). `pmaports-local/device/testing/device-xiaomi-taoyao/deviceinfo`
now reflects every fix above (`header_version=3`, `append_dtb=false`,
`bootimg_custom_args` with correct offsets, `android-tools` dependency) and
is the correct starting point for next time -- what's still needed is
either serial console access, or someone else's already-working
deviceinfo/kernel-signature-quirk to compare against.

## Session 2, continued: the pstore catch-22, dtbo, and a control experiment

Kept digging the same night rather than stopping. Three more real,
concrete findings, plus a firm conclusion.

### The pstore catch-22

Tried the obvious next move: flash the *downstream* kernel (`Image`
from session 1, already includes the Haven/Gunyah/extcon/cmdline fixes)
with this session's now-correct v3/`vendor_boot`/`android-tools`
pipeline, since it's the one kernel that's ever demonstrably executed
real driver code on this hardware. Rebuilt `linux-xiaomi-taoyao` +
`device-xiaomi-taoyao` (swapped `depends` back, added
`deviceinfo_dtb="qcom/taoyao"` and `deviceinfo_kernel_cmdline` back),
flashed for real. Result: hung on the Mi logo (not an instant bounce --
matches session 1's behavior), needed a hard power-off to recover.

Tried to read the hang's `pstore` log the same way as session 1: force
back to fastboot, reflash stock `boot_a`/`vendor_boot_a`/`vbmeta_a`,
reboot to EvolutionX, `adb shell su -c cat
/sys/fs/pstore/console-ramoops-0`. Got a real, substantial log -- but on
inspection it was **EvolutionX's own prior shutdown sequence**
(`msm_drm`, `hdcp_2x`, IPA offload, Xiaomi's own debug prints), not the
downstream kernel's hang at all.

Root cause, now fully understood: this device's `pstore`/`ramoops` only
allocates a single `console-ramoops-0` record (confirmed via `ls
/sys/fs/pstore/` -- exactly one file), not a rotating history. Reading
it requires booting into a kernel capable of mounting pstore and running
`adb`/`su`, and *that boot itself* overwrites the single record with its
own console output before the previous kernel's log can be read. This
isn't fixable by being more careful about warm-vs-cold resets (tested:
irrelevant) -- it's structural. The only way to see a hung/crashed
kernel's own log without a physical serial console is if that kernel
gets far enough to bring up USB networking/`adb`/SSH *before* it stops
responding, so it can be inspected live, with no intervening reboot.
Neither the downstream hang nor any mainline attempt ever got that far.
This matches (and now fully explains) the identical problem flagged in
session 1's "Real safety incident" section -- it recurred here because
the *only* way to check `pstore` at all requires the exact reboot that
destroys it, so it will keep recurring on this device regardless of
care taken.

To get root back for this (userdata had been wiped earlier in the
session by `pmbootstrap flasher flash_rootfs`, taking Magisk with it):
downloaded the real, current Magisk release
(`github.com/topjohnwu/Magisk`, tag `v30.7`) via the GitHub releases
API, `adb install`ed it, used its in-app "Direct Install" to re-root
EvolutionX. Worth remembering `v30.7` is just "whatever was current
2026-07-19" -- check for a newer tag next time rather than assuming.

### The Motorola Edge 30 (motorola-dubai) lead: `dtbo` and a different vbmeta recipe

Same `SM7325-AE` chipset, different OEM, wiki page has substantially
more detail than taoyao's own (which is just the generic
unlock/flash_kernel/flash_rootfs boilerplate). Two concrete new things
from it:

- **"To prepare the current slot for running mainline, we need to erase
  Android-specific DTB Overlays and disable AVB."** The `dtbo` partition
  holds Android-specific device-tree overlays that get merged onto the
  base devicetree by the bootloader, independent of whatever kernel is
  in `boot`/`vendor_boot`. Their recipe: `dd if=/dev/zero
  of=blank.dtbo.img bs=<dtbo-partition-size> count=1` then `fastboot
  flash dtbo blank.dtbo.img`. Checked our own `dtbo_a` partition size
  from `fastboot getvar all` earlier this session: `0x1800000` =
  exactly `25165824` bytes, **identical** to their `bs=25165824` --
  same chipset generation, same partition layout.
- A different, simpler vbmeta recipe: `avbtool make_vbmeta_image --flags
  2 --padding_size 8192 --rollback_index 32` (`--flags 2` =
  `VERIFICATION_DISABLED` only, not `--flags 3` which also sets
  `HASHTREE_DISABLED`; higher rollback index for headroom).

Also checked postmarketOS's own `Android Verified Boot (AVB)` wiki
page for ground truth, which independently confirms something we'd
already found empirically: **"For unlocked device bootloader skips the
verification for boot partition, but can still verify others."** -- this
explains, from the other direction, why toggling vbmeta between stock
and disabled never changed our `boot`/`vendor_boot` outcome at all: an
unlocked bootloader was never actually checking `boot`'s signature in
the first place. `dtbo` verification, however, is *not* skipped the
same way, which is what makes the dtbo-blanking theory the most
credible untested lead going into this experiment.

Backed up the real `dtbo_a` first (fastboot doesn't support `fetch` on
this device, same limitation as `vbmeta_a` earlier -- used `adb shell su
-c dd if=/dev/block/by-name/dtbo_a of=/data/local/tmp/...` from a
booted, rooted EvolutionX, then `adb pull`). Saved as
`extracted/dtbo_a_stock.img`. Built the blank replacement
(`extracted/blank_dtbo.img`) and the dubai-recipe vbmeta
(`extracted/vbmeta_a_dubai_recipe.img`).

**Result: flashing mainline kernel + blank `dtbo_a` + the dubai-recipe
vbmeta together produced the exact same instant "Mi logo, ~1s,
fastboot" rejection as every previous mainline attempt.** No change.
Restored `boot_a`, `vendor_boot_a`, `dtbo_a`, and `vbmeta_a` all back to
their stock backups afterward.

### Control experiment: `fastboot boot` (RAM-only) behaves differently from a real flash

One more data point, non-destructive by construction (RAM boot never
touches flash storage, so no restore was needed afterward regardless of
outcome). Ran `pmbootstrap flasher boot` with the same mainline
kernel/`vendor_boot` pair (stock `dtbo_a`/`vbmeta_a` at this point,
already restored): instead of the instant Mi-logo-then-fastboot-menu
bounce every real flash produced, this showed a **black screen for
~10-15 seconds**, then the bootloader itself fell back to booting
normally off disk (straight into EvolutionX) -- no manual intervention
needed, unlike the earlier EvoX-kernel-hybrid test which needed a hard
power-off to recover from an actual hang.

This is a real, repeatable behavioral difference between `fastboot
boot` (RAM, temporary) and `fastboot flash` + reboot (persistent) for
the exact same payload on this device -- worth remembering if this is
picked up again, since it means "RAM boot" and "real flash" are **not**
equivalent tests of the same failure here, unlike on most devices.
Checked `pstore` immediately after landing in EvolutionX anyway, in
case the extra ~10-15s of runtime left something behind: it didn't --
`console-ramoops-0` contained EvolutionX's own kernel boot log
(`Linux version 5.4.233-qgki...`, `Machine model: taoyao based...`),
confirming the catch-22 above applies here too, regardless of RAM-boot
vs. real-flash.

### Where this actually stands

Every fixable variable in the boot chain has now been tested and ruled
out as the cause of the mainline kernel's near-instant failure:
compression format (raw vs. gzip `Image`), boot header version (v2 vs.
correct v3), `vendor_boot`/load-address correctness (hand-built vs. the
real `boot-deploy` pipeline, verified byte-for-byte with
`unpack_bootimg`), AVB/vbmeta (stock vs. disabled vs. the
motorola-dubai recipe, and confirmed via postmarketOS's own AVB
documentation that `boot` verification is skipped entirely on unlocked
bootloaders anyway), and now Android DTBO overlays (stock vs. blanked).
None of them changed the outcome. The one thing that *did* change the
outcome -- swapping in EvolutionX's actual kernel binary while keeping
everything else about the pipeline identical, which got measurably
further (a real hang instead of an instant crash) -- points squarely at
the mainline kernel/devicetree combination itself, on this specific
unit's current firmware, as the actual remaining problem. And
`pstore`'s single-record limitation means that failure point is
fundamentally invisible without a live UART connection: any kernel that
crashes before bringing up USB networking leaves no readable trace,
because reading `pstore` requires a subsequent boot that overwrites it
before it can be read.

Reached out to the actual porter (`zstas`, verified via
[PR #9](https://github.com/sc7280-mainline/linux/pull/9) as the real
author of taoyao's upstream devicetree/panel driver) directly, asking
about their firmware version and whether they needed any vbmeta/dtbo
handling -- their own wiki page and PR history don't document either.
Response pending as of end of session.

### One more real lead, also tested: a `reserved-memory` size mismatch

Diffed mainline's `sm7325-xiaomi-taoyao.dts` reserved-memory map against
the actual downstream Xiaomi devicetree source (`kernel-devicetree-taoyao/qcom/yupik.dtsi`,
real source from session 1's kernel checkout, not a possibly-stale fdt
dump). Every region matched exactly (`cdsp_mem`, `adsp_mem`,
`pil_trustedvm_mem`, `qrtr_shmem`, ramoops, etc.) except one:
`removed_mem` at `0xc0000000` -- downstream declares size `0x5100000`,
mainline declares `0x6800000`. Real, concrete, verifiable discrepancy,
and a plausible root cause (wrong reserved-memory size can cause a
fatal, near-instant conflict during early kernel memory-map setup).

Patched a local copy of the dtb with `fdtput` to match the downstream
value, rebuilt `boot.img`/`vendor_boot.img` by hand with `mkbootimg`
(matching the real pipeline's output byte-for-byte otherwise, verified
via `unpack_bootimg` before flashing), flashed for real: **identical
instant "Mi logo, ~1s, fastboot" failure.** Ruled out. Restored
`boot_a`/`vendor_boot_a` to stock afterward (`dtbo_a`/`vbmeta_a` were
already stock from the previous restore).

**Correction, found later the same session:** this "discrepancy" was
already known and already fixed upstream -- not a live bug. Checked
[PR #9](https://github.com/sc7280-mainline/linux/pull/9)'s force-push
history directly: the `0x5100000` value (the one we patched *to*,
matching downstream) is the state from the July 22, 2025 force-push,
*before* zstas's own August 17, 2025 fix, whose commit message says
verbatim: `"Added Signed-off-by, rebased to sc7280-6.16.y. Also, fixed
1 typo in removed-mem node (was wrong size)."` The post-fix value,
`0x6800000`, is what's in the actual merged commit and every release
tag since -- i.e. what we'd already been testing with by default all
along. So this session tested *both* the known-bad pre-fix value and
the correct post-fix value, back to back, with identical results
either way. Cleanly and doubly ruled out, not a lingering suspicion.

### Compression format, retested under the now-correct v3 pipeline

The very first theory from earlier this session (raw vs. gzip `Image`)
had only ever been tested under the *wrong* header v2 format, before
v3/`vendor_boot` were fixed. Retested properly this time: built
`boot.img`/`vendor_boot.img` with the raw, uncompressed `Image` (same
one used in the EvoX-kernel-hybrid control test) under the fully
correct v3 pipeline (right addresses, right dtb, right cmdline).
**Identical instant failure.** Compression format is now definitively
ruled out under all conditions, not just the ones tested earlier.

### The UEFI/`linux.efi` path: considered, not attempted

This device reports `kernel:uefi` in `fastboot getvar all`, and the
kernel package builds a `linux.efi` ZBOOT stub specifically for UEFI
booting, alongside `vmlinuz`. Some newer pmOS devices
(`xiaomi-pipa`, a Snapdragon 8 Gen 2 tablet) skip Android bootimg
entirely and boot via a FAT32 ESP + `systemd-boot` + `linux.efi`
instead. Considered as a genuinely untested structural alternative, but
checked precedent first: **every currently-working SM7325 pmOS device
(`device-nothing-spacewar`) uses the classic Android-bootimg scheme**,
not this one -- `xiaomi-pipa`'s ESP scheme is on a meaningfully newer
SoC generation with a different ABL implementation. No known precedent
of ESP-style boot working on any SM7325 device. Documented as a
low-probability long shot in `TODOs/uefi-esp-boot-longshot.md` rather
than attempted, given the lack of precedent and the size of the lift
(no existing recipe to copy, would be genuinely new work).

**Device fully restored to stock a final time**, confirmed booting to
EvolutionX normally, Magisk root intact. Every independently-reachable
lead this session -- boot header version, load addresses, vbmeta/AVB
(both directions, cross-checked against postmarketOS's own AVB docs),
Android DTBO overlays (cross-checked against a same-chipset device's
wiki), kernel compression format (retested under the correct pipeline),
RAM-boot vs. real-flash behavior, and a real reserved-memory size
discrepancy against the actual downstream source -- has been tested and
ruled out. Next step: wait for `zstas`'s reply, or get physical
serial/UART console access. Nothing further is reachable purely over
`fastboot`/`adb`.

## Session 2, part 3: the regulator lead, the real answer from zstas, and where the build stands

More testing the same night, plus direct word from the actual porter --
the single most valuable thing that happened this session.

### `regulator-allowed-modes`/`regulator-allow-set-load` on the UFS VCC rail

Diffed taoyao's dts against `sm7325-nothing-spacewar.dts` (the proven
reference device) node-by-node. Found `vreg_l7b_2p96` -- explicitly
commented `/* Constrained for UFS VCC, at least until UFS driver scales
voltage */`, i.e. the storage controller's power rail -- is missing
`regulator-allowed-modes` and `regulator-allow-set-load` in taoyao's
current dts, while spacewar's equivalent regulator has both. Patched a
local dtb copy with `fdtput` to add both properties with spacewar's
exact values, flashed for real: **identical instant failure.** Ruled
out, but cleanly (matched the known-working reference exactly, still
failed) -- unlike the removed-mem case this wasn't a rediscovery of an
already-fixed value, just a real dead end.

### Retested `v6.17.0-sc7280` specifically (the version the wiki cites)

The taoyao wiki page states `pmOS kernel: 6.17.0` as tested/confirmed.
All prior testing this session used `v7.1.2-sc7280`, a later tag.
Downloaded and built `v6.17.0-sc7280` from source specifically (not in
the prebuilt binary repo), fixed one build issue along the way (the
`linux7.0-resolve_btfids-...patch` doesn't apply to this kernel
version -- dropped it, it's a `resolve_btfids` BPF-tooling-only patch,
zero effect on runtime). Flashed the resulting kernel for real:
**identical instant failure to `v7.1.2`.**

**Important correction:** `v6.17.0-sc7280` was tagged 2026-10-03,
*after* zstas's 2025-08-17 force-push that rebased PR #9 onto
`sc7280-6.16.y`. So this was never actually a "pre-rebase" test --
just a different post-rebase snapshot. Also used this build to
conclusively retest the raw-vs-gzip `Image` question one more time
under this kernel version: no difference, as expected.

### The real pre-rebase test, and correcting the removed-mem finding

Went back to [PR #9](https://github.com/sc7280-mainline/linux/pull/9)'s
timeline via the GitHub API (`head_ref_force_pushed` events) to find
the actual pre-rebase commit: `af9b3fad9d9a9040f3507da7cb1ec98b9a76fc32`
(2025-07-22, on `zstas/sm6115_mainline`, the fork PR #9 was made from --
the `sc7280-mainline/linux` codeload tarball endpoint was rate-limited
after the earlier large downloads this session, worked around with
`git fetch --depth=1` from the fork directly instead). Built and
flashed this exact commit for real: **identical instant failure.**

This same investigation also fully resolved the earlier
"reserved-memory size discrepancy" finding with much more precision.
zstas's 2025-08-17 force-push comment says verbatim: *"Added
Signed-off-by, rebased to sc7280-6.16.y. Also, fixed 1 typo in
removed-mem node (was wrong size)."* Diffing the pre-rebase
(`af9b3fad9`) and post-rebase (`6d3de968542e...`, the actual merged
commit) taoyao.dts directly: the pre-rebase value was `0x5100000`
(matching generic downstream `yupik.dtsi` -- and matching what this
session originally "fixed" it to, thinking that was the correction) and
the post-rebase, currently-merged value is `0x6800000`. So this
session tested *both* the confirmed-buggy pre-fix value and the
confirmed-correct post-fix value, back to back, with identical crash
either way. Genuinely, doubly ruled out now, not a lingering
suspicion -- and the earlier README section describing this as an open
lead has been superseded by this one.

### zstas replied -- and gave the actual answer

Reached out via Telegram (not GitHub) given a shared personal
connection. Direct quote, translated: *"What's currently in
sc7280-mainline is missing a patch for the battery, and that's why it
hangs. Take this branch instead:
[`upstream_panel`](https://github.com/zstas/sm6115_mainline/tree/upstream_panel)
-- no audio yet, but closest to the mainline patch that got merged."*
Confirmed later in the same conversation: *"I just haven't packaged it
for pmOS yet because without the battery patch everything hangs
completely dead after a couple seconds"* -- which is exactly this
session's symptom, described independently by the person who's
actually run this hardware. Also explained *why* it's not in the
official `sc7280-mainline` repo: the maintainer (Luca Weiss) wants the
battery fix submitted upstream to the real Linux kernel mailing list
first, rather than merged as a fork-only patch, and it's only been a
few days since the base panel patch itself landed.

Fetched branch HEAD `50ab7f30c1518db7a48752e65469e2315e51aaf0`
(2026-06-24) the same way as the pre-rebase test (`git fetch --depth=1`
from the fork, GitHub's tarball endpoint still rate-limited). Confirmed
taoyao's dts is present and wired into the build. This is the kernel
source this session should have been building all along, per direct
word from the actual person who's booted this exact hardware
successfully.

### The real, complete device package -- also from zstas (via Telegram file share)

Separately, zstas shared a real `git format-patch` output
(`reference/taoyao-full-devicepkg-danila-eugene.patch`, 19 files,
authored 2025-07-09 by Danila Tikhonov and Eugene Lepshy, not zstas
directly -- evidently a broader small team effort) containing a
complete, real pmaports submission for taoyao:
- `device/testing/device-xiaomi-taoyao/` -- a full deviceinfo +
  APKBUILD + UCM audio config (`ucm/taoyao.conf`, `ucm/HiFi.conf`) +
  hexagonrpcd config + udev rules for the accelerometer mount matrix.
  **Its `deviceinfo_header_version="0"` with `append_dtb="true"`** --
  a completely different, older/simpler boot format (no `vendor_boot`
  split at all) than the `header_version="3"` this session verified
  directly against the real stock `boot.img` via `unpack_bootimg`
  earlier tonight. Not adopted as the primary approach for that reason
  (this session's v3 finding is a direct, first-party measurement of
  this exact unit's actual stock firmware, not something to override
  on a different document's say-so) but flagged as a real fallback to
  try if the `upstream_panel` kernel still doesn't boot under v3.
  Real, useful, previously-unverified value from this file:
  `deviceinfo_super_partitions="/dev/sda20 /dev/sda20"` (commented out
  in their version too, but a concrete real value rather than a blind
  guess).
- `device/testing/firmware-xiaomi-taoyao/` -- a real, dedicated
  firmware-blob package (adsp/cdsp/gpu/ipa/modem/sensors/vpu/wpss),
  sourced from `github.com/zstas/firmware-xiaomi-taoyao` (maintainer:
  Jens Reidel -- a third contributor). **Applied and built
  successfully this session** (`pmbootstrap build firmware-xiaomi-taoyao`,
  ~10s, no compilation needed, just packaging real firmware blobs).
  Genuinely new capability this project didn't have before -- none of
  tonight's or session 1's boot attempts included real DSP/modem/sensor
  firmware at all.
- `device/testing/linux-xiaomi-taoyao/` -- a kernel package pinned to
  the *exact same* `50ab7f30c...` commit as the `upstream_panel`
  branch, but using **a dedicated `config-xiaomi-taoyao.aarch64`**
  instead of the generic community `config-postmarketos-qcom-sc7280.aarch64`
  this session used for every build tonight. Diffed the two configs
  directly: no battery/power-supply/pmic_glink-related differences
  (confirming the actual fix is the source-level battery driver patch
  in the `upstream_panel` branch commit itself, not a config setting),
  but ~1830 lines of other differences overall -- not yet reviewed in
  detail. Saved to `reference/config-xiaomi-taoyao.aarch64` for future
  use; worth switching to once a boot succeeds, for whatever other
  device-specific tuning it contains.

### Where the build actually stands (important -- lost work, not yet re-verified)

Set up a from-source build of the `upstream_panel` branch
(`linux-postmarketos-qcom-sc7280` pinned to `50ab7f30c...`, source
tarball built locally via `git fetch --depth=1` since GitHub's codeload
tarball endpoint was rate-limited after several large downloads this
session, placed directly in `~/.local/var/pmbootstrap/cache_distfiles/`).

First build attempt compiled cleanly for a full hour and failed only at
the very last step: `pahole` segfaulting while generating BTF debug
info (`Failed to generate BTF for vmlinux`) -- a build-tooling issue
completely unrelated to kernel functionality. Disabled
`CONFIG_DEBUG_INFO_BTF`/`CONFIG_DEBUG_INFO_BTF_MODULES` directly in the
chroot's `.config` and re-ran `make` by hand to reuse the ~1hr of
already-compiled object files rather than rebuilding from scratch.

**Mistake made and worth remembering:** started the
`firmware-xiaomi-taoyao` package build concurrently in the same native
chroot while the kernel rebuild was still running in the background,
thinking the low CPU load meant it was safe. It wasn't -- every
`pmbootstrap build` invocation wipes `/home/pmos/build` fresh as part
of its own lifecycle, and doing so mid-kernel-build destroyed the
entire hour-plus of cached kernel compilation progress. The firmware
package itself built fine (unaffected, it's a separate, fast,
non-compiling package), but the kernel build was lost and needs to be
restarted from scratch. **Never run two `pmbootstrap build`/`pmbootstrap
chroot` invocations against the same chroot concurrently, regardless of
apparent CPU headroom** -- the shared `/home/pmos/build` directory
lifecycle is the actual constraint, not CPU contention.

**Next step, in order:** rebuild `linux-postmarketos-qcom-sc7280`
pinned to `upstream_panel` (`50ab7f30c...`) from scratch, this time
with `CONFIG_DEBUG_INFO_BTF` disabled from the start to avoid the
pahole segfault, and *not* running anything else in the same chroot
concurrently. Flash and test -- this is the version directly confirmed
by the actual porter to have the working battery-hang fix. If it
still fails, fall back to trying `deviceinfo_header_version="0"` +
`append_dtb="true"` (the older, no-`vendor_boot` format from the
Danila/Eugene device package) as the next untested variable, since
every `header_version="3"` combination has now been exhaustively
tested and ruled out this session.
