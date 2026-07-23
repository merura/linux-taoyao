# SXMO ("Simple X Mobile", also ships a Sway/Wayland variant called "swmo"),
# via wentam/sxmo-nix (github.com/wentam/sxmo-nix) -- there's no sxmo
# packaging in nixpkgs itself, this is the most complete third-party port.
#
# Uses swmo (the Wayland/sway session) rather than sxmo (the X11 session):
# no Xorg stack needed, and it's the better fit alongside Phosh/phoc and
# Plasma Mobile/kwin_wayland, which are both Wayland-only on this device.
#
# `evalWith` (mobile-nixos' release-tools.nix) doesn't support specialArgs,
# so this file is a function returning a module rather than a module that
# takes sxmoNixSrc directly -- called as
# `(import ./modules/sxmo.nix { inherit sxmoNixSrc; })` from flake.nix.
{ sxmoNixSrc }:

{ config, lib, pkgs, ... }:

{
  imports = [
    (import ./sxmo-upstream-patched.nix { inherit sxmoNixSrc; })
    (import ./sxmo-tinydm-patched.nix { inherit sxmoNixSrc; })
    (import ./sxmo-deviceprofile.nix { inherit sxmoNixSrc; })
  ];

  # tinydm asserts services.xserver.enable; we don't want a real Xorg
  # server running (swmo is Wayland-only), but the display-manager
  # scaffolding (session files, autologin, job wrapper) still lives under
  # the xserver module tree in this nixpkgs revision.
  services.xserver.enable = true;

  services.xserver.desktopManager.sxmo.enable = true;

  services.xserver.displayManager.tinydm.enable = true;
  services.displayManager.autoLogin = {
    enable = true;
    user = "user";
  };
  services.displayManager.defaultSession = "swmo";
}
