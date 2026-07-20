# Mobile NixOS for Xiaomi 12 Lite 5G (taoyao)

Out-of-tree [Mobile NixOS](https://github.com/NixOS/mobile-nixos) port for
`xiaomi-taoyao` (Qualcomm SM7325 / Snapdragon 778G+), derived from the working
postmarketOS port in the parent directory.

Minimal and headless: console + SSH over the USB gadget, no GUI.

## Layout

```
flake.nix                          nixpkgs 26.05 (pinned) + mobile-nixos
configuration.nix                  minimal system, users, SSH over USB
devices/xiaomi-taoyao/
  default.nix                      device definition (ported from deviceinfo)
  kernel/default.nix               zstas/sm6115_mainline @ 0b867a74
  kernel/config.aarch64            pmOS config + CONFIG_DRM_FBDEV_EMULATION=y
  firmware/default.nix             zstas/firmware-xiaomi-taoyao @ fb9b96dd
modules/
  soc-sm7325.nix                   SM7325 SoC (not shipped by mobile-nixos)
  panel-fix.nix                    boot-time panel brightness workaround
```

## Why these specific pieces

- **SM7325 SoC module** — mobile-nixos ships sdm845/sc7180/sm6125/... but not
  SM7325, and `mobile.hardware.soc` asserts the SoC is known, so it is declared
  out of tree.
- **Kernel commit `0b867a74`** — earlier commits either hang at boot or never
  light the panel.
- **`CONFIG_DRM_FBDEV_EMULATION=y`** — without it the DRM driver never creates
  `/dev/fb0` and the screen stays black after the bootloader hands off.
- **`panel-fix.nix`** — the panel latches `brightness=0` at boot; see section
  10 of `../README.md`.
- **Boot image offsets** — taken verbatim from the pmOS `deviceinfo`; they
  happen to match mobile-nixos' sdm845 family values.

## Build

```bash
nix build .#boot-image     # android boot image for fastboot
nix build .#default        # rootfs / fastboot images
```

Cross-compiled from x86_64; `mobile.system.system = "aarch64-linux"` makes
mobile-nixos set up `nixpkgs.buildPlatform`/`hostPlatform` automatically.

Handy debugging targets: `.#kernel`, `.#firmware`, `.#device-metadata`.

## Flash

The device is A/B and the bootloader silently falls back to the other slot
after failed boots, so flash **both** slots and erase the stale Android
`dtbo`/`vendor_boot` on both — see section 6 of `../README.md`.

## Access

SSH over the USB gadget, same addressing as the pmOS install:

- device `172.16.42.1`, host gets `172.16.42.2` via DHCP
- users `root` / `user`, initial password `pmos1234` (change it), authorized
  keys preinstalled, passwordless sudo for `wheel`
