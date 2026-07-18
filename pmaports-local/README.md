# pmaports scaffold for taoyao

Not a real pmaports checkout — just the new package directories being
drafted for taoyao, meant to be dropped into a real `pmaports` clone
(e.g. the one `pmbootstrap init` creates) once finished. See the
top-level `../README.md` for full context and status.

- `device/testing/device-xiaomi-taoyao/` — device package: `deviceinfo`,
  `APKBUILD`, firmware/udev rules if needed.
- `device/testing/linux-xiaomi-taoyao/` — kernel package: packages the
  `Image` + dtb produced by the from-scratch build in `../kernel-taoyao/`
  (see top-level README step 5), it does not rebuild the kernel itself.

Status: scaffolding only, not yet functional. Reference used for
`deviceinfo` values: `device-nothing-spacewar` in upstream pmaports
(same SM7325 chipset), cross-checked against our own extracted
`boot.img`/`vendor_boot.img` offsets.
