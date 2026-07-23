# Local copy of sxmo-nix's modules/sxmo/default.nix (from
# github:wentam/sxmo-nix), patched for this nixpkgs revision: that repo's
# copy sets `services.logind.extraConfig`, which this nixpkgs has turned
# into a hard `mkRemovedOptionModule` error (renamed to
# services.logind.settings.Login) -- any definition of the old option
# fails the build regardless of mkDefault, so it has to be fixed at the
# source rather than overridden from another module.
#
# Everything else here is unchanged from upstream.
{ sxmoNixSrc }:

{ config, options, lib, pkgs, ... }:

let
  sxmopkgs = import ./sxmo-nix-packages.nix { inherit sxmoNixSrc pkgs; };
  dmcfg = config.services.xserver.desktopManager;
in
{
  options = {
    services.xserver.desktopManager.sxmo = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "";
      };
    };
    services.xserver.desktopManager.sxmo.package = lib.mkOption {
      type = lib.types.package;
      default = sxmopkgs.sxmo-utils;
      description = "sxmo-utils package to use";
    };
  };

  config = lib.mkIf config.services.xserver.desktopManager.sxmo.enable {
    environment.systemPackages = [
      dmcfg.sxmo.package
      sxmopkgs.superd
      # sxmo_init.sh's $BROWSER defaults to "firefox", but no browser was
      # actually installed. File manager and PDF viewer aren't part of
      # sxmo-utils either (it ships a terminal, image viewer, media
      # player, RSS/gopher reader, but no GUI file browser or document
      # viewer) -- same gap as the other two DE variants on this device.
    ] ++ (with pkgs; [
      firefox
      pcmanfm
      zathura
    ]);

    services.udev.packages = [ dmcfg.sxmo.package ];  # Install udev rules
    fonts.packages = [ pkgs.nerd-fonts.symbols-only ]; # Sxmo uses nerdfonts for it's icons
    powerManagement.enable = lib.mkDefault true;       # For suspend
    services.libinput.enable = lib.mkDefault true;

    # Needed for sxmo to find it's hooks/superd services, and for the user's
    # local sxmo configuration to reference resources without needing to migrate
    # for every single nix store path change.
    environment.pathsToLink = [ "/share" ];

    services.displayManager.sessionPackages = [ dmcfg.sxmo.package ];

    # Power button shouldn't immediately power off the device
    # (sxmo uses it for menus etc)
    services.logind.settings.Login.HandlePowerKey = lib.mkDefault "ignore";

    # Sxmo uses doas to run these commands as root. We need to allow that.
    # sxmo-utils provides this config, but we shouldn't ask the application
    # what the application is permitted to run as root :)
    #
    # As such, we maintain it here.
    #
    # Note: this allows *any wheel user* to run the commands prefixed with 'nopass' here
    # as root without a password. This isn't too bad, because generally it's intended
    # that wheel users have access to the root account in some way.
    security.doas.enable = true;
    security.doas.extraConfig = ''
     permit persist :wheel
     permit nopass :wheel as root cmd busybox args poweroff
     permit nopass :wheel as root cmd busybox args reboot
     permit nopass :wheel as root cmd poweroff
     permit nopass :wheel as root cmd systemctl args poweroff
     permit nopass :wheel as root cmd rtcwake
     permit nopass :wheel as root cmd reboot
     permit nopass :wheel as root cmd sxmo_wifitoggle.sh
     permit nopass :wheel as root cmd sxmo_bluetoothtoggle.sh
     permit nopass :wheel as root cmd systemctl args restart bluetooth
     permit nopass :wheel as root cmd tinydm-set-session
     permit nopass :wheel as root cmd systemctl args start eg25-manager
     permit nopass :wheel as root cmd systemctl args stop eg25-manager
     permit nopass :wheel as root cmd systemctl args start ModemManager
     permit nopass :wheel as root cmd systemctl args stop ModemManager
     permit setenv { NIX_PATH } :wheel as root cmd nohup args nixos-rebuild switch --upgrade
    '';

    # Sxmo uses rtcwake to suspend the system, we need
    # setuid to give it access
    security.wrappers."rtcwake" = {
      setuid = true;
      source = "${pkgs.util-linux}/bin/rtcwake";
      owner  = "root";
      group  = "wheel";
    };

    # After ~2.3 minutes idle (120s lock + 8s screenoff + 8s to the
    # suspend-triggering daemon), sxmo runs a real system suspend
    # (sxmo_hook_screenoff.sh -> sxmo_mutex.sh can_suspend holdexec
    # sxmo_suspend.sh), which kills the USB gadget link (and everything
    # else) along with the rest of the system -- this is why SSH/USB
    # access disappears whenever the screen has been locked for a while.
    # sxmo's own `can_suspend` mutex is the built-in way other things
    # (e.g. an active call) block suspend from happening at all: `lock`
    # just appends a reason string to a small state file and returns
    # (not a long-running hold), and `holdexec` refuses to run
    # sxmo_suspend.sh as long as that file is non-empty. Pre-lock it
    # every session so suspend never actually triggers -- screen
    # lock/dim/DPMS-off still happens normally for battery savings, only
    # the deep-suspend stage is skipped.
    systemd.user.services.sxmo-never-suspend = {
      description = "Prevent sxmo from suspending (keeps USB/SSH alive)";
      wantedBy = [ "default.target" ];
      # sxmo_mutex.sh sources sxmo_common.sh via a bare `.  sxmo_common.sh`
      # (PATH lookup, not a relative/absolute path), which fails outside
      # a real sxmo session shell unless sxmo-utils' own bin/ is on PATH.
      path = [ dmcfg.sxmo.package ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = ''${dmcfg.sxmo.package}/bin/sxmo_mutex.sh can_suspend lock "never-suspend (nixos config)"'';
      };
    };
  };
}
