# TODO (long shot): try the UEFI/ESP + systemd-boot native boot path

Not attempted -- documented here instead, after session 2 exhausted every
other reachable lead for the mainline kernel's instant boot failure
(see `../README.md`'s "Session 2" sections for the full list of what
was tried and ruled out: header version, load addresses, vbmeta/AVB,
Android DTBO overlays, kernel compression format, a real
reserved-memory size discrepancy against the downstream source).

## The idea

This device reports `kernel:uefi` in `fastboot getvar all`, and the
mainline kernel package (`linux-postmarketos-qcom-sc7280`) already
builds `linux.efi` (a ZBOOT EFI decompressor stub) specifically for
UEFI booting, alongside the `vmlinuz` we've been using for the Android
bootimg path. Some newer pmOS devices skip Android bootimg entirely and
boot via a FAT32 ESP partition containing `systemd-boot` + `linux.efi`
+ loader entries, set via `deviceinfo_boot_filesystem="fat32"` with
`deviceinfo_generate_bootimg` left unset. `xiaomi-pipa` (Xiaomi Pad 6)
in real pmaports is configured exactly this way.

## Why it's a long shot, not a real lead

Checked: **every currently-working SM7325 pmOS device uses the classic
Android-bootimg scheme, not this one.** `device-nothing-spacewar` (same
chipset family, confirmed working on the wiki) sets
`generate_bootimg=true` + `header_version=2`/no `boot_filesystem` at
all -- the classic scheme. `xiaomi-pipa`'s ESP/`systemd-boot` setup is
on a Snapdragon 8 Gen 2 (SM8550) tablet, a meaningfully newer SoC
generation where Qualcomm's ABL implementation genuinely changed to
support real UEFI ESP discovery on the boot partition. There is no
known precedent of the ESP scheme working on *any* SM7325 device.
`kernel:uefi` in `getvar` most likely just describes that this
generation's ABL is *internally implemented* using UEFI/EDK2
framework code, not that it exposes a generic UEFI boot-services
interface capable of discovering an arbitrary ESP the way a PC BIOS/UEFI
would -- this is normal for basically every Qualcomm Android device
since ~Snapdragon 660, unrelated to whether ESP-style boot actually
works.

## If this is ever attempted anyway

Would need, at minimum:
- `deviceinfo_boot_filesystem="fat32"`, remove `deviceinfo_generate_bootimg`
  and the header-version/offset fields entirely
- A hand-built FAT32 image containing `EFI/BOOT/BOOTAA64.EFI`
  (systemd-boot), `loader/loader.conf` + entries, `linux.efi`, and the
  initramfs, written raw to `boot_a` via `fastboot flash boot_a`
  (`boot_a` is a raw-flashed partition regardless of what filesystem it
  contains, so this is mechanically possible even without GPT
  partition-type changes -- the open question is purely whether the
  ABL will actually *look* for and boot from it there)
- No existing recipe for this specific chipset/partition-layout
  combination to copy from; would be genuinely new, unproven work, not
  a documented fix

Given the precedent evidence above, this is unlikely to be worth
attempting before other options (waiting on `zstas`'s reply, physical
serial console access) are exhausted.
