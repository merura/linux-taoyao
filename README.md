# postmarketOS on Xiaomi 12 Lite 5G (taoyao)

Working install procedure using zstas's mainline kernel fork. Device is not yet
merged into pmaports, so this uses a manual device patch (`taoyao.patch`).

## Prerequisites

- Unlocked bootloader (`fastboot getvar all` should show `unlocked: yes`,
  `Device unlocked: true`, `Device critical unlocked: true`)
- `pmbootstrap`, `fastboot`, `adb` installed on the host
- `taoyao.patch` (adds `device-xiaomi-taoyao`, `firmware-xiaomi-taoyao`,
  `linux-xiaomi-taoyao` to pmaports)

## 1. Clone pmaports and apply the device patch

Use the current upstream URL, **not** `gitlab.com/postmarketos/pmaports.git`
(outdated remote — pmbootstrap will refuse to read `channels.cfg` from it).

```bash
git clone https://gitlab.postmarketos.org/postmarketOS/pmaports.git
cd pmaports
git apply /path/to/taoyao.patch
git add -A
git commit -m "new device xiaomi taoyao"
```

## 2. Use the correct kernel commit

The pmaports patch pins `linux-xiaomi-taoyao` to a commit on
`zstas/sm6115_mainline` that has a broken panel driver (`DSI PLL(0) lock
failed`, permanent black screen, boot otherwise fine). The working commit is:

```
0b867a7442d7d780dee52a04904a758386761f57
```

Edit `device/testing/linux-xiaomi-taoyao/APKBUILD`:

```sh
_commit="0b867a7442d7d780dee52a04904a758386761f57"
```

and update `sha512sums` for the tarball to match (GitHub's codeload archives
are not byte-reproducible across separate downloads — compute the checksum
from whatever copy you actually feed to abuild, don't reuse one fetched
separately):

```bash
sha512sum linux-xiaomi-taoyao-0b867a7442d7d780dee52a04904a758386761f57.tar.gz
```

## 3. Kernel config fix: enable DRM fbdev emulation

Even with the working panel commit, the shipped
`config-xiaomi-taoyao.aarch64` has:

```
# CONFIG_DRM_FBDEV_EMULATION is not set
```

Without it, the DRM driver never creates `/dev/fb0`. The bootloader's
`simple-framebuffer` hands off to the real DPU/DSI driver during boot (the
brief ~0.1s flash you see), and with no `/dev/fb0` there is nothing left for
`fbcon`/plymouth to draw to — permanent black screen, even though the panel
driver itself probes cleanly (confirm via `dmesg | grep -i 'DSI PLL'` showing
nothing, and `/sys/class/backlight/*/brightness` reporting real values).

Fix:

```sh
CONFIG_DRM_FBDEV_EMULATION=y
```

Recompute and update the `config-xiaomi-taoyao.aarch64` checksum in the same
`APKBUILD` after editing.

## 4. pmbootstrap setup

Non-interactive config (`~/.config/pmbootstrap_v3.cfg`), pointing at your
patched local pmaports checkout:

```ini
[pmbootstrap]
aports = /path/to/pmaports
device = xiaomi-taoyao
ui = console
work = /home/user/.local/var/pmbootstrap
jobs = <nproc>
build_pkgs_on_install = True

[providers]

[mirrors]
```

Then run `pmbootstrap init` once to finish first-time setup (clone/branch
selection, chroot bootstrap) — accepting defaults for everything is fine
since the config file above already pins device/aports/UI.

## 5. Build

```bash
pmbootstrap build device-xiaomi-taoyao linux-xiaomi-taoyao firmware-xiaomi-taoyao
pmbootstrap install --password <temporary-password> --zap
```

## 6. Flash

Put the device in fastboot (Volume Down + Power). The device is A/B — **flash
and clean up both slots**, since the bootloader auto-switches slots after a
few failed boots, silently reverting to whatever (possibly stock) partitions
sit in the other slot:

```bash
# Both slots' dtbo/vendor_boot must be erased — mainline doesn't use them,
# and stale stock ones cause the same instant Mi-logo→fastboot failure
# regardless of which kernel you flash.
fastboot erase dtbo_a
fastboot erase dtbo_b
fastboot erase vendor_boot_a
fastboot erase vendor_boot_b

fastboot erase userdata
fastboot erase boot_a
fastboot erase boot_b

pmbootstrap flasher flash_kernel   # regenerates boot.img, flashes to boot_a
fastboot flash boot_b /home/user/.local/var/pmbootstrap/chroot_rootfs_xiaomi-taoyao/boot/boot.img

pmbootstrap flasher flash_rootfs  # flashes rootfs to userdata (shared, not slot-specific)

# Erase dtbo/vendor_boot again in case the flash_kernel step recreated anything unexpected
fastboot erase dtbo_a
fastboot erase dtbo_b
fastboot erase vendor_boot_a
fastboot erase vendor_boot_b

fastboot set_active a
fastboot reboot
```

## 7. First boot

- USB networking comes up automatically; if the host doesn't get a DHCP
  lease, assign one manually in the same subnet as the device
  (`172.16.42.1`):

  ```bash
  sudo ip addr add 172.16.42.2/24 dev <usb-interface>
  ```

- SSH: `ssh user@172.16.42.1`, password set during `pmbootstrap install`.
- Each fresh install regenerates SSH host keys — clear the stale entry
  first: `ssh-keygen -R 172.16.42.1`.

## 8. Convenience: SSH keys + passwordless sudo

Optional, but useful once the device is reachable:

```bash
ssh user@172.16.42.1 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys' < your-github-username.keys
# (e.g. curl -s https://github.com/<user>.keys as the source of authorized keys)

ssh user@172.16.42.1 'sudo sh -c "echo \"user ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/user-nopasswd && chmod 440 /etc/sudoers.d/user-nopasswd"'
```

Note: this lives on `userdata`, so a full reinstall (anything that erases
`userdata`) wipes it and it needs to be redone. A kernel-only reflash (like
step 3's fix) does **not** touch this.

## 9. Installing a graphical UI (phosh)

Once the device has any network access (USB gadget to the host, or straight
WiFi via `nmtui` — both work once you're booted), it's much simpler to
install a UI on-device with `apk` than to rebuild/reflash:

```bash
ssh user@172.16.42.1
sudo apk update
sudo apk add postmarketos-ui-phosh
```

This pulls in `phosh`, `phoc`, `feedbackd`, and their dependencies. `apk
update`/`add` against the `edge/testing` index can be slow/stall-looking on
first fetch — it's not actually stuck, just give it a minute.

After install, reboot (or start the relevant seat/greetd service) to get the
graphical session. No `pmbootstrap` rebuild or reflash needed for this step.

## 10. Black screen fix (panel latches brightness=0 at boot)

Even with everything above correct, the screen can stay completely black
while the system boots fine (SSH works, no failed units). This is **not** a
missing/wrong panel driver — it is a boot-time ordering bug.

Symptoms, all simultaneously true:

- `dmesg` shows **no** `DSI PLL(0) lock failed`, panel driver probes cleanly
- `/sys/class/drm/card0-DSI-1/` → `connected`, `enabled`, dpms `On`
- `/sys/kernel/debug/dri/0/state` → `crtc-0: enable=1, active=1`, mode
  `1080x2400`, fbcon plane attached
- `/dev/fb0` contains real rendered content (non-zero bytes)
- but `/sys/class/backlight/ae94000.dsi.0/actual_brightness` reads **0**
  while `brightness` reads `4095`

The panel is scanning out frames correctly and simply emitting no light: the
DCS brightness command is issued before the panel will accept it, so
brightness latches at 0. Writing `brightness` afterwards returns success but
`actual_brightness` stays 0.

A full panel power cycle re-runs `unprepare()` → `prepare()` at a point where
the brightness write sticks:

```bash
echo 4 > /sys/class/graphics/fb0/blank   # power panel down
sleep 1
echo 0 > /sys/class/graphics/fb0/blank   # power panel up (re-init)
sleep 1
cat /sys/class/backlight/ae94000.dsi.0/max_brightness \
    > /sys/class/backlight/ae94000.dsi.0/brightness
```

`actual_brightness` then reads `4095` and the display works.

`panel-fix/` in this repo automates that at boot. Install with:

```bash
install -Dm755 panel-fix/taoyao-panel-fix /usr/local/bin/taoyao-panel-fix
install -Dm644 panel-fix/taoyao-panel-fix.service \
    /etc/systemd/system/taoyao-panel-fix.service
systemctl daemon-reload
systemctl enable --now taoyao-panel-fix.service
```

The service must run **late** (`After=multi-user.target`) and the script waits
for `fb0`/backlight to appear — running it early in boot silently no-ops
because the display pipeline isn't up yet.

This is a workaround, not a real fix; the ordering bug belongs in the panel
driver (`panel-xiaomi-taoyao-csot-nt36672c.c`).

## Known issues (as of this build)

- **Battery**: `qcom-battmgr-bat/usb/wls` uevent failures in dmesg — WIP
  upstream, not fixed in this kernel yet.
- **Audio**: not present in this kernel branch yet (maintainer is working on
  it separately).
- **GPU firmware**: `adreno_request_fw` fails to load `a660_sqe.fw` — no 3D
  acceleration yet.
- **Display**: needs the boot-time workaround in section 10.

## Credits

- pmaports device patch, kernel fork: Stanislav Zaikin (zstas)
- Panel driver / DSI PLL fix: commit `0b867a7442d7d780dee52a04904a758386761f57`
- Shared mainline kernel base for SC7280/SM7325/QCM6490: Luca Weiss
  (`sc7280-mainline/linux`)
