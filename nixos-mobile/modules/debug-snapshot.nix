# Periodic system-state snapshot, printed to stdout so the already-working
# persistent journal captures it -- retrievable after a crash from any
# later boot via `journalctl -u debug-snapshot -b -N` (or -1, -2, ... for
# older boots; see `journalctl --list-boots`).
#
# Temporary debugging aid for the depmod/USB-instability investigation;
# remove once that's closed out.
{ config, lib, pkgs, ... }:

{
  systemd.services.debug-snapshot = {
    description = "Print a diagnostic system-state snapshot to the journal";
    serviceConfig.Type = "oneshot";
    path = with pkgs; [
      coreutils
      util-linux
      procps
      iproute2
      kmod
      systemd
    ];
    script = ''
      # NixOS wraps `script` with `set -e`, but this is a best-effort
      # diagnostic dump -- individual commands (e.g. `cat` on a glob that
      # doesn't match any rfkill devices) can legitimately fail depending
      # on system state, and one failure shouldn't abort the whole
      # snapshot silently.
      set +e

      echo "=== $(date -Is) (uptime: $(cut -d' ' -f1 /proc/uptime)) ==="

      echo "--- systemctl is-system-running / --failed ---"
      systemctl is-system-running || true
      systemctl --failed --no-legend

      echo "--- ip link / usb0 addr ---"
      ip link
      ip -4 addr show usb0 2>&1
      ip -6 addr show usb0 2>&1

      echo "--- usb gadget functions ---"
      ls /sys/kernel/config/usb_gadget/g1/functions/ 2>&1

      echo "--- lsmod ---"
      lsmod

      echo "--- rfkill ---"
      cat /sys/class/rfkill/*/state 2>&1
      cat /sys/class/rfkill/*/name 2>&1

      echo "--- power_supply / battery ---"
      for f in /sys/class/power_supply/*/uevent; do
        echo "-- $f --"
        cat "$f" 2>&1
      done

      echo "--- thermal zones ---"
      for f in /sys/class/thermal/thermal_zone*/temp; do
        echo -n "$f: "; cat "$f" 2>&1
      done

      echo "--- free / load ---"
      free -h
      cat /proc/loadavg

      echo "=== end snapshot ==="
    '';
  };

  systemd.timers.debug-snapshot = {
    description = "Periodic diagnostic system-state snapshot";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10s";
      OnUnitActiveSec = "20s";
      AccuracySec = "1s";
    };
  };
}
