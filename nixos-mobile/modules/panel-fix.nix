# Workaround: the taoyao panel latches brightness=0 at boot.
#
# The display pipeline comes up correctly (DSI PLL locks, crtc active, fbcon
# plane attached, real content in /dev/fb0) but the panel emits no light:
# the DCS brightness command is issued before the panel will accept it, so
# actual_brightness stays 0 while brightness reads max. Writing brightness
# afterwards returns success and changes nothing.
#
# A full panel power cycle re-runs the panel's unprepare()/prepare() at a
# point where the brightness write sticks.
#
# This is a workaround; the ordering bug belongs in
# panel-xiaomi-taoyao-csot-nt36672c.c.
{ config, lib, pkgs, ... }:

let
  cfg = config.mobile.quirks.xiaomi-taoyao.panel-brightness-fix;
in
{
  options.mobile.quirks.xiaomi-taoyao.panel-brightness-fix.enable =
    lib.mkEnableOption "the taoyao boot-time panel brightness workaround" // {
      default = true;
    };

  config = lib.mkIf cfg.enable {
    systemd.services.taoyao-panel-fix = {
      description = "Work around taoyao panel latching brightness=0 at boot";
      # Must run late: earlier in boot the display pipeline does not exist
      # yet and this silently no-ops.
      after = [ "multi-user.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        FB=/sys/class/graphics/fb0/blank
        BL=/sys/class/backlight/ae94000.dsi.0

        # Wait for the DRM panel + backlight to appear (up to 30s).
        i=0
        while [ $i -lt 60 ]; do
          [ -e "$FB" ] && [ -e "$BL/actual_brightness" ] && break
          sleep 0.5
          i=$((i + 1))
        done
        [ -e "$FB" ] || exit 0
        [ -e "$BL/actual_brightness" ] || exit 0

        # Let the panel finish coming up before poking it.
        sleep 3

        # Nothing to do if the panel is already lit.
        [ "$(cat "$BL/actual_brightness")" != "0" ] && exit 0

        echo 4 > "$FB"
        sleep 1
        echo 0 > "$FB"
        sleep 1
        cat "$BL/max_brightness" > "$BL/brightness"
      '';
    };
  };
}
