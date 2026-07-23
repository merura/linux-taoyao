# SXMO has no built-in device profile for this device (checked
# sxmo-utils' scripts/deviceprofiles/ -- no xiaomi,taoyao entry). It
# resolves the profile name from the first string in
# /proc/device-tree/compatible (comma preserved, only non
# alnum/./,/- chars get replaced with '_'), which on this device is
# literally "xiaomi,taoyao" -- confirmed via
# `tr "\0" "\n" < /proc/device-tree/compatible`.
#
# Rather than patching sxmo-utils' own derivation, ship this as its own
# tiny package: deviceprofiles are just plain executable scripts sxmo
# looks up via `command -v`, so anything on $PATH under the right name
# works, no need to modify the upstream sxmo-utils build.
#
# `evalWith` doesn't support specialArgs (see modules/sxmo.nix), so this
# is a function returning a module, called as
# `(import ./sxmo-deviceprofile.nix { inherit sxmoNixSrc; })`.
{ sxmoNixSrc }:

{ pkgs, ... }:

let
  sxmopkgs = import ./sxmo-nix-packages.nix { inherit sxmoNixSrc pkgs; };
in
{
  environment.systemPackages = [
    (pkgs.writeTextFile {
      name = "sxmo-deviceprofile-xiaomi-taoyao";
      destination = "/bin/sxmo_deviceprofile_xiaomi,taoyao.sh";
      executable = true;
      text = ''
        #!/bin/sh
        # Xiaomi 12 Lite 5G / SM7325 ("taoyao")
        # SPDX-License-Identifier: AGPL-3.0-only

        export SXMO_MONITOR="DSI-1"

        # From /proc/bus/input/devices: pmic_pwrkey is vendor=0/product=0,
        # gpio-keys is vendor=1/product=1, pmic_resin is vendor=0/product=0.
        # sway's input device identifier is
        # "<vendor>:<product>:<name, spaces->underscore>".
        export SXMO_POWER_BUTTON="0:0:pmic_pwrkey"

        # The volume rocker is split across TWO separate kernel input
        # devices on this board, not one: gpio-keys only has volume-up
        # (confirmed via the devicetree -- /sys/firmware/devicetree/base/
        # gpio-keys has just a single "key-volume-up" child node, no
        # volume-down at all), while volume-down is actually routed
        # through pmic_resin (confirmed via `libinput debug-events`:
        # pressing volume-down fires real KEY_VOLUMEDOWN events on
        # /dev/input/event1, the pmic_resin device). sxmo_swayinitconf.sh
        # loops over $SXMO_VOLUME_BUTTON as a space-separated list of
        # device identifiers (see e.g. upstream's own
        # vayu/Poco-X3-Pro profile using two devices the same way), so
        # both need to be listed here for both directions to work.
        export SXMO_VOLUME_BUTTON="1:1:gpio-keys 0:0:pmic_resin"

        # 1080x2400 panel; matches the scale=2 already used in Phosh's
        # phoc.ini for the same physical screen.
        export SXMO_SWAY_SCALE="2"
      '';
    })

    # sxmo_init.sh builds $PATH from
    # `xdg_data_path "sxmo/default_hooks/$SXMO_DEVICE_NAME"`, and
    # sxmo_hook_inputhandler.sh (the script that actually dispatches
    # power/volume button presses -- confirmed via
    # ~/.local/state/tinydm.log showing "sxmo_hook_inputhandler.sh:
    # command not found" every time a button was pressed) only exists
    # under sxmo-utils' own default_hooks/<archetype>/ subdirectories,
    # never at the top level. Every other phone gets there via a
    # per-device symlink baked into sxmo-utils itself (e.g.
    # "xiaomi,beryllium -> three_button_touchscreen"); ours doesn't
    # exist since this device isn't in sxmo's built-in list. This
    # device is the same archetype (single power key + volume rocker +
    # touchscreen, no physical keyboard) as every other phone that maps
    # to it, so symlink the same way.
    (pkgs.runCommand "sxmo-default-hooks-xiaomi-taoyao" { } ''
      mkdir -p $out/share/sxmo/default_hooks
      ln -s ${sxmopkgs.sxmo-utils}/share/sxmo/default_hooks/three_button_touchscreen \
        "$out/share/sxmo/default_hooks/xiaomi,taoyao"
    '')
  ];
}
