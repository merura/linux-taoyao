# pmaports scaffold for taoyao

Not a real pmaports checkout — just the new package directory being
drafted for taoyao, meant to be dropped into a real `pmaports` clone
(e.g. the one `pmbootstrap init` creates) once finished. See the
top-level `../README.md` for full context and status — in particular
the "Pivot to mainline" section, since this scaffold changed
significantly there.

- `device/testing/device-xiaomi-taoyao/` — device package: `deviceinfo` +
  `APKBUILD`, using the standard `devicepkg_build`/`devicepkg_package`
  helpers from `devicepkg-dev`. Depends on the existing
  `linux-postmarketos-qcom-sc7280` mainline kernel package (already in
  pmaports, not something we build) instead of building our own kernel.
- `device/testing/linux-xiaomi-taoyao/` — **superseded, kept for
  reference only, not depended on by anything anymore.** Our own
  from-scratch downstream-kernel package (packages `Image`/`taoyao.dtb`
  from `../build-output/`, built per `../README.md` steps 1-10). Real
  work, hit a boot hang that needed hardware (serial console) to debug
  further; see `../README.md`'s "Pivot to mainline" for why this was set
  aside in favor of a maintained, already-working mainline kernel.

`deviceinfo` values are based on `device-nothing-spacewar` (same SM7325
chipset, same kernel package now too) cross-checked against our own
extracted `boot.img`/`vendor_boot.img` offsets — see top-level
`../README.md` step 1. Those hardware/bootloader facts (flash offsets,
header version, etc.) stayed valid across the kernel-source pivot, since
they're independent of which kernel is running.

## Known gaps — not yet functional end-to-end

- **`deviceinfo_super_partitions` is unset.** taoyao is A/B with dynamic
  partitions (`super.img`), and this field is very likely required for
  flashing to work correctly (`device-nothing-spacewar` sets it to a
  device-specific block path). Deliberately left unset rather than
  copying another device's value — it's a real partition path specific
  to that device's layout, not something safe to guess. Determine the
  real value on-device before attempting to flash (see the comment in
  `deviceinfo` for the commands to check).
- Not yet flashed for real — only `pmbootstrap flasher boot` (RAM-only,
  non-destructive) attempted so far, and not yet with the new mainline
  `deviceinfo`/`APKBUILD`. This is the current next step.
