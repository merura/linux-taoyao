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
- **Flashed for real, repeatedly, in session 2 — boots the bootloader's
  own splash then instantly dies.** `deviceinfo_header_version="3"` (not
  `"2"` — that was a real bug, fixed in session 2 after confirming via
  `unpack_bootimg` on our own stock `boot.img` backup that this device
  is header v3, split `boot_a`/`vendor_boot_a`), `append_dtb="false"`,
  `bootimg_custom_args` set with the correct load addresses (boot-deploy
  doesn't forward `flash_offset_*` for header v3/v4, only
  `bootimg_custom_args` — without it `mkbootimg` silently defaults to
  the wrong base), and `android-tools` in `depends` (the generic
  `mkbootimg` virtual resolves to `mkbootimg-osm0sis`, which doesn't
  support v3/v4 at all). All of this produces a real, pipeline-verified,
  correctly-addressed `boot.img`/`vendor_boot.img` pair — and it still
  crashes within ~1 second of getting control, before UART/framebuffer
  come up. See the top-level `../README.md` "Session 2" section for the
  full isolation work (vbmeta ruled out, EvoX-kernel comparison test)
  and why this now needs a physical serial console to go further.
