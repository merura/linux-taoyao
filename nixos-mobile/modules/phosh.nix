# Phosh (Phone Shell), enabled as an opt-in module rather than baked into
# configuration.nix, since the base config is meant to stay a minimal
# headless console for bring-up/debug work.
{ config, lib, pkgs, ... }:

{
  mobile.beautification = {
    silentBoot = lib.mkDefault true;
    splash = lib.mkDefault true;
  };

  services.xserver.desktopManager.phosh = {
    enable = true;
    user = "user";
    group = "users";
  };

  programs.calls.enable = true;

  environment.systemPackages = with pkgs; [
    epiphany      # Web browser
    gnome-console # Terminal
  ];

  hardware.sensor.iio.enable = true;

  # A fresh boot reproducibly hangs completely (no USB/adb/console
  # activity at all, needs a hard power-cycle) reaching graphical.target
  # -- which phosh's nixpkgs module pulls in via
  # `services.graphical-desktop.enable`. This never happened when phosh
  # was started manually (`systemctl start phosh`) from an
  # already-running multi-user.target session, so the hang is specific to
  # something in the boot-time transition into graphical.target itself,
  # not phosh/phoc. Until that's root-caused (can't be debugged remotely
  # since the hang leaves no USB/adb access at all), keep multi-user.target
  # as the actual boot default and only start phosh manually.
  systemd.defaultUnit = lib.mkForce "multi-user.target";

  # phoc (the wlroots compositor Phosh runs on) uses libseat, which needs
  # systemd-logind to mark its session "active" on a seat before it'll open
  # the DRM device. Every VT (tty1..tty6) gets autologin as root, since the
  # autologin override lands on the getty@.service *template*, not just
  # tty1 -- with more than one VT auto-spawned, whichever VT last had
  # kernel-console focus at boot becomes logind's "active" session, and if
  # that isn't phosh's tty1 session, phoc's libseat backend waits forever
  # ("Timeout waiting session to become active") and never opens the DRM
  # device. This device has one physical screen, so there's no reason to
  # auto-spawn more than one VT in the first place.
  services.logind.settings.Login.NAutoVTs = 1;
}
