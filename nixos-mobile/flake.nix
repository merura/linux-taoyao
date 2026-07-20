{
  description = "Mobile NixOS for Xiaomi 12 Lite 5G (xiaomi-taoyao / SM7325)";

  inputs = {
    # Stable 26.05, pinned to the exact revision from ~/dotfiles/flake.lock
    # so this shares a store/binary cache with the rest of the machine.
    nixpkgs.url = "github:NixOS/nixpkgs/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca";

    # Mobile NixOS is not a flake; consume it as a plain source tree.
    mobile-nixos = {
      url = "github:NixOS/mobile-nixos";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, mobile-nixos }:
    let
      # Build host. The target (aarch64) is selected by the device module via
      # `mobile.system.system`; mobile-nixos' system-target.nix then sets up
      # nixpkgs.buildPlatform/hostPlatform for cross-compilation.
      buildSystem = "x86_64-linux";

      pkgs = import nixpkgs { system = buildSystem; };

      # Fix cross-compilation of the kernel.
      #
      # kernel/builder.nix hands the *target* `writeShellScript` to
      # eval-config.nix, so the generated config-validator snippet gets a
      # shebang pointing at aarch64 bash. That script runs on the build host
      # during the kernel's configurePhase, so it dies with
      # "bad interpreter: No such file or directory" (exit 126).
      # `buildPackages` is already in scope there; just use it.
      mobile-nixos-src = pkgs.applyPatches {
        name = "mobile-nixos-cross-fix";
        src = mobile-nixos;
        postPatch = ''
          substituteInPlace overlay/mobile-nixos/kernel/builder.nix \
            --replace-fail \
              'inherit lib path version writeShellScript;' \
              'inherit lib path version; writeShellScript = buildPackages.writeShellScript;'
        '';
      };

      device = ./devices/xiaomi-taoyao;

      eval = (import "${mobile-nixos-src}/lib/release-tools.nix" {
        inherit pkgs;
      }).evalWith {
        inherit device;
        modules = [ ./configuration.nix ];
      };

      outputs' = eval.config.mobile.outputs;
    in
    {
      nixosConfigurations.taoyao = eval;

      packages.${buildSystem} = {
        # Android boot image (kernel + initrd + appended DTB) for fastboot.
        boot-image = outputs'.android.android-bootimg;

        # Full rootfs image.
        default = outputs'.default or outputs'.android.default;

        # Handy for debugging the port.
        inherit (outputs') device-metadata;
        kernel = eval.config.mobile.boot.stage-1.kernel.package;
        firmware = eval.config.mobile.device.firmware;
      };

      devShells.${buildSystem}.default = pkgs.mkShell {
        packages = with pkgs; [ android-tools ];
      };
    };
}
