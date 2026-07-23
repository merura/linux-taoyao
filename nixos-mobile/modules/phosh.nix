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

  # Needed for the dconf daemon/database mechanism generally (settings
  # persistence etc). Each nixpkgs-wrapped GNOME binary already points at
  # its own schemas via its own wrapper-set XDG_DATA_DIRS, so this isn't
  # what makes squeekboard show up automatically -- that's the profile
  # below.
  programs.dconf.enable = true;

  # Phosh's virtual-keyboard auto-show only fires if GNOME's "screen
  # keyboard" accessibility toggle is on, which is off by default (it's
  # an opt-in a11y feature in stock GNOME, not something that defaults on
  # just because a device is a phone). Pre-seed it so squeekboard pops up
  # on text-field focus without the user having to dig through Settings
  # first.
  programs.dconf.profiles.user.databases = [
    {
      settings = {
        "org/gnome/desktop/a11y/applications" = {
          screen-keyboard-enabled = true;
        };
      };
    }
  ];

  programs.calls.enable = true;

  # Make Firefox the default browser (no home-manager here, so this has to
  # be a plain mimeapps.list rather than xdg.mimeApps).
  environment.etc."xdg/mimeapps.list".text = ''
    [Default Applications]
    text/html=firefox.desktop
    x-scheme-handler/http=firefox.desktop
    x-scheme-handler/https=firefox.desktop
  '';

  environment.systemPackages = with pkgs; [
    firefox       # Web browser (no touch-optimized mobile build exists on
                  # Linux; this is the same desktop Firefox, which is what
                  # every mobile Linux distro uses in practice)
    gnome-console # Terminal
    stevia        # On-screen keyboard -- Phosh's own GTK4/libadwaita
                  # successor to squeekboard, version-matched (0.54.0) to
                  # this phosh/phoc build, and ships its own systemd user
                  # unit (unlike squeekboard, which needed one hand-written).
    phosh-mobile-settings
    gnome-calculator
    gnome-clocks
    gnome-weather
    gnome-contacts
    gnome-calendar
    gnome-control-center
    # chatty (SMS/IM) deliberately left out -- it depends on `olm`, marked
    # insecure in this nixpkgs revision.
  ];

  # Unlike squeekboard, stevia ships its own systemd user unit (built via
  # its `-Dsystemd_user_unit_dir` meson flag), so no hand-written unit is
  # needed here.
  #
  # Note: auto-show-on-focus depends on the app actually sending a
  # text-input-v3 "enable" request when a field gets touch focus, which is
  # a known gap for some GTK/touch input paths (confirmed via phoc's own
  # compositor log showing zero input-method activity on a touch tap) --
  # not something fixable from this end. Phosh's home-bar / bottom-bar
  # gesture toggles the keyboard manually regardless of that gap.

  hardware.sensor.iio.enable = true;

  # The earlier graphical.target boot hang was suspected to be caused by
  # the same qcom_q6v5_pas/remoteproc early-boot race that was breaking
  # USB (see configuration.nix) -- now blacklisted, so graphical.target
  # is back to being the real default. If this regresses, the
  # debug-snapshot service (see modules/debug-snapshot.nix) should catch
  # it this time, unlike before.
}
