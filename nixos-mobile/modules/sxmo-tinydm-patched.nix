# Local copy of sxmo-nix's modules/tinydm/default.nix, patched: the
# original does its own `sxmopkgs = import ../../default.nix { inherit pkgs; };`
# which re-derives an UNPATCHED tinydm (still has the busybox buildInput
# that breaks the build, see sxmo-nix-packages.nix) as a second, separate
# package instance -- completely bypassing the fix there. Point this at
# our patched sxmo-nix-packages.nix instead so there's only one tinydm.
{ sxmoNixSrc }:

{ config, options, lib, pkgs, ... }:

with lib;

let
  sxmopkgs = import ./sxmo-nix-packages.nix { inherit sxmoNixSrc pkgs; };
  dmcfg = config.services.xserver.displayManager;
in
{
  imports = [
    "${sxmoNixSrc}/modules/autologin"
  ];
  options = {
    services.xserver.displayManager.tinydm = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "";
      };
    };
  };

  config = lib.mkIf config.services.xserver.displayManager.tinydm.enable {
    assertions = [
      {
        assertion = config.services.xserver.enable;
        message = ''
          TinyDM requires services.xserver.enable to be true.
        '';
      }
      {
        assertion = dmcfg.autoLogin.enable;
        message = ''
          TinyDM requires services.xserver.displayManager.autoLogin.enable to be true.
        '';
      }
      {
        assertion = dmcfg.autoLogin.enable -> dmcfg.sessionData.autologinSession != null;
        message = ''
          TinyDM auto-login requires services.xserver.displayManager.defaultSession to be set.
        '';
      }
    ];

    systemd.services.display-manager.enable = true;
    services.displayManager.generic.enable = true;
    services.xserver.displayManager.lightdm.enable = false;

    programs.autologin.enable = true;

    environment.systemPackages = [ sxmopkgs.tinydm ];

    systemd.services.tinydm-setup = {
      description = "Tinydm setup";
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "/var/lib/tinydm/";
        User = "root";
        Group = "root";
        ExecStart = ''${pkgs.busybox}/bin/rm -f /var/lib/tinydm/default-session.desktop'';
      };
    };

    services.displayManager.preStart =
      let
        xsession_path = "${dmcfg.sessionData.desktops}/share/xsessions/";
        wsession_path = "${dmcfg.sessionData.desktops}/share/wayland-sessions/";
      in
      ''
        if [ ! -e /var/lib/tinydm/default-session.desktop ]; then
          if [ -e ${xsession_path}/${dmcfg.defaultSession}.desktop ]; then
            ${sxmopkgs.tinydm}/bin/tinydm-set-session -f -s ${xsession_path}/${dmcfg.defaultSession}.desktop
          fi

          if [ -e ${wsession_path}/${dmcfg.defaultSession}.desktop ]; then
            ${sxmopkgs.tinydm}/bin/tinydm-set-session -f -s ${wsession_path}/${dmcfg.defaultSession}.desktop
          fi
        fi
      '';

    services.xserver.displayManager.startx.enable = true;

    systemd.services.display-manager.after = [ "getty@tty1.service" "systemd-user-sessions.service" ];
    systemd.services.display-manager.conflicts = [ "getty@tty1.service" ];

    systemd.services.display-manager.serviceConfig.RestartSec = lib.mkOverride 10 3;

    services.displayManager.generic.execCmd = ''
      exec ${sxmopkgs.autologin}/bin/autologin ${dmcfg.autoLogin.user} ${sxmopkgs.tinydm}/bin/tinydm-run-session
    '';
  };
}
