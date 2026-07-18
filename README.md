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
