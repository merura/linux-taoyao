# KDE Plasma Mobile, as an alternative to Phosh -- a separate
# nixosConfiguration (taoyao-plasma-mobile) rather than a runtime-switchable
# option, since the two use entirely different compositors (kwin_wayland vs
# phoc) and session infrastructure (SDDM vs phosh's own systemd unit).
{ config, lib, pkgs, ... }:

{
  # SDDM needs at least one of xserver.enable or sddm.wayland.enable; we
  # want the Wayland kwin_wayland session, not a full Xorg stack.
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };

  # No physical keyboard and no confirmed-working on-screen keyboard for
  # SDDM's own (non-Phosh) greeter, so skip the greeter entirely and log
  # straight into the session, same rationale as Phosh's setup.
  services.displayManager.autoLogin = {
    enable = true;
    user = "user";
  };

  services.displayManager.defaultSession = "plasma-mobile";
  services.displayManager.sessionPackages = [ pkgs.kdePackages.plasma-mobile ];

  programs.dconf.enable = true;

  # plasmashell logs "starting invalid corona org.kde.plasma.mobileshell"
  # and exits -- the shell package IS present in plasma-mobile's own store
  # path (share/plasma/shells/org.kde.plasma.mobileshell), but
  # environment.pathsToLink's default is a curated allowlist of share/
  # subdirectories that doesn't include share/plasma, so it never reaches
  # /run/current-system/sw and plasmashell's KPackage lookup can't find it.
  environment.pathsToLink = [ "/share/plasma" ];

  # SDDM's session command is `plasma-dbus-run-session-if-needed`, which
  # falls back to exec'ing bare `dbus-run-session` when
  # $DBUS_SESSION_BUS_ADDRESS isn't already set (the case for a fresh
  # autologin session). mobile-nixos gives every systemd unit a minimal,
  # explicit PATH (coreutils/findutils/grep/sed/systemd only, no dbus) --
  # without this, that exec fails with 127, the autologin session dies
  # instantly, and SDDM silently falls back to showing its own greeter
  # (which needs a keyboard we don't have a working one for here).
  # `.path` additions here go on the unit's own literal PATH env var, not
  # /run/current-system/sw/bin -- systemPackages alone isn't enough for
  # anything the session command execs directly (only /run/current-system/
  # sw/bin gets populated from systemPackages, and this unit's PATH doesn't
  # include that directory).
  systemd.services.display-manager.path = with pkgs; [ dbus kdePackages.plasma-workspace ];

  # ksplashqml (the boot splash) crashes with SIGABRT on startup (no
  # useful backtrace, no debug symbols available) and was blocking the
  # rest of the session from coming up. Purely cosmetic -- mask it rather
  # than debug a crash in a non-essential component.
  systemd.user.services.plasma-ksplash.enable = false;

  # startplasma-wayland's "systemd boot mode" exits with code 4
  # ("Could not start Plasma session") because it tries to start
  # plasma-workspace-wayland.target via `systemctl --user start`, and that
  # unit is never found: plasma-workspace/plasma-mobile ship their user
  # units under their own store path's share/systemd/user/, but nixpkgs has
  # no equivalent of `systemd.packages` for *user* units (systemPackages
  # only merges share/ into /run/current-system/sw/share, which isn't on
  # systemd's user-unit search path at all -- confirmed via
  # `systemd-analyze --user unit-paths`). Tried environment.etc first, but
  # that collides with NixOS's own declarative management of
  # /etc/systemd/user ("Permission denied" building the etc derivation).
  # /run/current-system/sw/etc/xdg/systemd/user *is* on the search path and
  # is just an ordinary systemPackages profile merge (no /etc involved), so
  # ship the unit files as their own tiny package instead.
  environment.systemPackages = with pkgs; [
    kdePackages.plasma-mobile
    # plasma-mobile's startplasmamobile script execs startplasma-wayland,
    # which lives in plasma-workspace's own bin/ -- plasma-mobile only
    # pulls it in as a library dependency, so its bin/ never gets merged
    # into the system profile's PATH without listing it explicitly here.
    kdePackages.plasma-workspace
    # plasma-workspace-wayland.target Requires=/BindsTo=
    # plasma-kwin_wayland.service, which is shipped by the kwin package
    # itself (not plasma-workspace) -- without kwin in this list, that
    # unit is never found, systemctl --user start on the target fails
    # immediately, and kwin_wayland never even gets a chance to run. This
    # was the actual cause of startplasma-wayland's exit(4) ("Could not
    # start Plasma session").
    kdePackages.kwin
    # kwin_wayland's invocation always includes --xwayland/--xwayland-fd
    # flags, and the Xwayland binary wasn't installed at all (confirmed
    # via `which Xwayland`), so this is needed regardless -- but it turned
    # out NOT to be the cause of the SIGSEGV crash loop below (still
    # crashed identically with this added).
    xwayland
    # The actual SIGSEGV cause (found via gdb + kwin's debug symbols on a
    # coredump): kwin_wayland crashes inside QApplicationPrivate::
    # handleThemeChanged(), called from its own QApplication constructor
    # (KWin::Application::Application, main.cpp:89) -- i.e. it crashes
    # immediately on startup trying to query the Qt platform theme, and
    # plasma-integration (the actual "kde" QPA platform theme plugin) was
    # completely missing from the system (confirmed: no libplasmaintegration
    # or *platformtheme* files anywhere under /run/current-system/sw).
    kdePackages.plasma-integration
    # plasmashell: "Aborting shell load: The activity manager daemon
    # (kactivitymanagerd) is not running." -- a separate package, wasn't
    # installed at all.
    kdePackages.kactivitymanagerd
    # plasmashell: "module org.kde.plasma.private.volume is not
    # installed" (needed by the mobileshell homescreen's AudioInfo.qml).
    # Proactively adding the other usual per-feature QML-plugin providers
    # too (network, bluetooth, display config) since this is clearly a
    # per-package pattern -- plasma-workspace only ships the shell host,
    # not the actual feature plugins.
    kdePackages.plasma-pa
    kdePackages.plasma-nm
    kdePackages.bluedevil
    kdePackages.bluez-qt
    kdePackages.kscreen
    kdePackages.konsole
    firefox

    (
      let
        # plasmashell loads plasma-mobile's Desktop.qml corona fine, but
        # then fails to load its QML plugins (org.kde.plasma.private.
        # mobileshell and its .state/.shellsettingsplugin/.windowplugin
        # submodules -- "module ... is not installed"): those live under
        # plasma-mobile's own store path (lib/qt-6/qml/org/kde/plasma/
        # private/mobileshell/), but plasmashell is a *different* package
        # (plasma-workspace) whose own Qt wrapper has no reason to know
        # about plasma-mobile's QML plugin dir.
        #
        # Tried three different ways to inject NIXPKGS_QT6_QML_IMPORT_PATH
        # (the nixpkgs-specific var this Qt build actually reads, per its
        # own makeCWrapper dump -- not the standard QML2_IMPORT_PATH,
        # which had zero effect) as a plain environment variable:
        # systemd.services.display-manager.environment (never reaches
        # plasma-plasmashell.service -- that's a *user* unit, managed by
        # the separate per-user systemd instance, which does not blindly
        # inherit the system unit's env) and systemd.user.extraConfig's
        # DefaultEnvironment= (writes to /etc/systemd/user.conf correctly,
        # confirmed by reading the file back, but still never showed up
        # in the actual plasmashell process's /proc/<pid>/environ either).
        # Rather than chase a fourth env-propagation layer, rewrap the
        # plasmashell binary itself so the path is baked in at exec time,
        # independent of any of that.
        plasmashellWrapped = pkgs.runCommand "plasmashell-with-mobileshell-qml"
          { nativeBuildInputs = [ pkgs.makeWrapper ]; }
          ''
            makeWrapper ${kdePackages.plasma-workspace}/bin/plasmashell $out/bin/plasmashell \
              --prefix NIXPKGS_QT6_QML_IMPORT_PATH : ${kdePackages.plasma-mobile}/lib/qt-6/qml \
              --prefix NIXPKGS_QT6_QML_IMPORT_PATH : ${kdePackages.plasma-pa}/lib/qt-6/qml \
              --prefix NIXPKGS_QT6_QML_IMPORT_PATH : ${kdePackages.plasma-nm}/lib/qt-6/qml \
              --prefix NIXPKGS_QT6_QML_IMPORT_PATH : ${kdePackages.bluedevil}/lib/qt-6/qml \
              --prefix NIXPKGS_QT6_QML_IMPORT_PATH : ${kdePackages.bluez-qt}/lib/qt-6/qml \
              --prefix NIXPKGS_QT6_QML_IMPORT_PATH : ${kdePackages.kscreen}/lib/qt-6/qml
          '';
      in
      pkgs.runCommand "plasma-mobile-user-units" { } ''
        mkdir -p $out/etc/xdg/systemd/user
        for pkg in ${kdePackages.plasma-workspace} ${kdePackages.plasma-mobile} ${kdePackages.kwin} ${kdePackages.kactivitymanagerd} ${kdePackages.plasma-pa} ${kdePackages.plasma-nm} ${kdePackages.bluedevil} ${kdePackages.bluez-qt} ${kdePackages.kscreen}; do
          if [ -d "$pkg/share/systemd/user" ]; then
            for f in "$pkg/share/systemd/user"/*; do
              # Skip plasma-ksplash.service: masked via
              # systemd.user.services.plasma-ksplash.enable = false above.
              # /run/current-system/sw/etc/xdg/systemd/user (this package's
              # target dir) is searched *before* /etc/systemd/user (where
              # NixOS puts that mask) in systemd's unit-path priority order,
              # so shipping our own copy here would silently override it.
              # Also skip plasma-plasmashell.service: patched separately
              # below to point at the rewrapped binary.
              name="$(basename "$f")"
              [ "$name" = "plasma-ksplash.service" ] && continue
              [ "$name" = "plasma-plasmashell.service" ] && continue
              ln -sf "$f" "$out/etc/xdg/systemd/user/$name"
            done
          fi
        done

        sed "s|ExecStart=.*plasmashell.*|ExecStart=${plasmashellWrapped}/bin/plasmashell --no-respawn|" \
          "${kdePackages.plasma-workspace}/share/systemd/user/plasma-plasmashell.service" \
          > "$out/etc/xdg/systemd/user/plasma-plasmashell.service"

        # kactivitymanagerd ships a D-Bus service file that would normally
        # auto-activate on first use, but plasmashell just does a
        # synchronous "is this already running" check on startup and aborts
        # immediately if not -- it doesn't wait for/trigger D-Bus
        # activation. So it has to be already running by the time
        # plasmashell starts. NixOS's own systemd.user.services.<name>.
        # wantedBy option doesn't work here: it creates the .wants symlink
        # under /etc/systemd/user/, pointing at a unit file that only
        # exists in THIS package's own tree -- a dangling symlink systemd
        # silently ignores. Create the .wants symlink ourselves, in the
        # same tree as the real unit file.
        mkdir -p "$out/etc/xdg/systemd/user/plasma-core.target.wants"
        ln -sf ../plasma-kactivitymanagerd.service \
          "$out/etc/xdg/systemd/user/plasma-core.target.wants/plasma-kactivitymanagerd.service"
      ''
    )
  ];
}
