# pmaports scaffold for taoyao

Not a real pmaports checkout — just the new package directories being
drafted for taoyao, meant to be dropped into a real `pmaports` clone
(e.g. the one `pmbootstrap init` creates) once finished. See the
top-level `../README.md` for full context and status.

- `device/testing/device-xiaomi-taoyao/` — device package: `deviceinfo` +
  `APKBUILD`, using the standard `devicepkg_build`/`devicepkg_package`
  helpers from `devicepkg-dev`.
- `device/testing/linux-xiaomi-taoyao/` — kernel package. Currently
  packages the already-built `Image`/`taoyao.dtb` from `../build-output/`
  (symlinked in, see `APKBUILD`'s `source=`) rather than building from
  source inside the package — see the note at the top of that
  `APKBUILD` and `../TODOs/dual-build.md` for the plan to change that
  later, using `devicepkg-dev`'s `downstreamkernel_prepare`/
  `downstreamkernel_package` helpers (found by reading
  `main/devicepkg-dev/*.sh` in a sparse pmaports checkout — these are
  the real, current helpers for exactly this kind of package, discovered
  after confirming no live pmaports device still uses them as a
  from-source example to copy).

`deviceinfo` values are based on `device-nothing-spacewar` (same SM7325
chipset, closest real pmaports device) cross-checked against our own
extracted `boot.img`/`vendor_boot.img` offsets — see top-level
`../README.md` step 1.

## Known gaps — not yet functional end-to-end

- **`deviceinfo_super_partitions` is unset.** taoyao is A/B with dynamic
  partitions (`super.img`), and this field is very likely required for
  flashing to work correctly (`device-nothing-spacewar` sets it to a
  device-specific block path). Deliberately left unset rather than
  copying another device's value — it's a real partition path specific
  to that device's layout, not something safe to guess. Determine the
  real value on-device before attempting to flash (see the comment in
  `deviceinfo` for the commands to check).
- **No kernel modules packaged.** `linux-xiaomi-taoyao`'s `package()`
  only installs `Image`/`taoyao.dtb`/`kernel.release` — no
  `modules_install` was run (the build in `../README.md` only built
  `Image dtbs`, not `modules`). Anything in the QGKI defconfig set to
  `=m` won't be available at boot. Fine for a first bring-up attempt to
  see if it boots at all; needs fixing before the device is actually
  usable.
- Not yet run through `pmbootstrap` at all — no `pmbootstrap init`/
  `install` attempted, no flash attempted, no boot attempted.
