{
  description = ''
    Mobile NixOS for Xiaomi 12 Lite 5G (xiaomi-taoyao / SM7325).

    EXPERIMENT (branch fresh-nixos-mobile-native): evaluate the whole system
    as genuinely NATIVE aarch64-linux (no crossSystem), so most packages hit
    Hydra's native aarch64 binary cache instead of building locally. Only the
    kernel is still built via true cross-compilation (x86_64 -> aarch64),
    since it is never cached either way and cross-compiling it is much
    faster than compiling it under QEMU emulation.

    Requires this machine to actually be able to build aarch64-linux
    derivations, i.e. `boot.binfmt.emulatedSystems = [ "aarch64-linux" ];`
    in the host's NixOS configuration (~/dotfiles), applied via
    `nixos-rebuild switch`. Without that, mobile.hardware building or the
    rootfs build here will fail to find a builder for aarch64-linux.
  '';

  inputs = {
    # Stable 26.05, pinned to the exact revision from ~/dotfiles/flake.lock
    # so this shares a store/binary cache with the rest of the machine.
    nixpkgs.url = "github:NixOS/nixpkgs/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca";

    # Mobile NixOS is not a flake; consume it as a plain source tree.
    mobile-nixos = {
      url = "github:NixOS/mobile-nixos";
      flake = false;
    };

    # Third-party NixOS packaging of SXMO/swmo -- not in nixpkgs itself.
    sxmo-nix = {
      url = "github:wentam/sxmo-nix";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, mobile-nixos, sxmo-nix }:
    let
      # The system flake commands are invoked from.
      buildSystem = "x86_64-linux";
      # The system we are actually targeting. Passing this as `system` (not
      # `crossSystem`) to `import nixpkgs` below is what makes the build
      # *native* rather than cross: mobile-nixos' system-target.nix computes
      # `isCross = deviceHostPlatform.system != localSystem.system`, and here
      # both sides are "aarch64-linux".
      targetSystem = "aarch64-linux";

      # `pkgs` used for the *whole* system eval: genuinely native aarch64,
      # built here via QEMU emulation (requires boot.binfmt.emulatedSystems
      # on the host, see the description above). This is what lets almost
      # everything come from cache.nixos.org instead of building locally.
      pkgs = import nixpkgs { system = targetSystem; };

      # A separate x86_64 pkgs, used only to build the *cross-compiled*
      # helper eval below. The kernel is our own out-of-tree commit/config,
      # so it is never going to be cache-hit regardless of approach; cross
      # compiling it natively on the x86_64 build host is far faster than
      # compiling it under QEMU emulation (a full kernel build spawns
      # thousands of `cc1` invocations, each paying emulation overhead).
      pkgsForCrossKernel = import nixpkgs { system = buildSystem; };

      # `mobile-nixos.kernel-builder`'s `structuredConfig` argument is
      # populated by an overlay added by modules/kernel-config.nix -- only
      # present when evaluating through the full module system (it reads
      # `config.mobile.kernel.structuredConfig`). So rather than hand-call
      # `kernel-builder` outside that context (where it silently gets `{}`
      # and crashes calling it as a function), do a second full `evalWith`
      # identical to the main one except left as x86_64 -> aarch64 cross
      # (the same approach the `fresh` branch uses), purely to pull a
      # working kernel package out of it.
      crossEval = (import "${mobile-nixos-src}/lib/release-tools.nix" {
        pkgs = pkgsForCrossKernel;
      }).evalWith {
        inherit device;
        modules = [ ./configuration.nix ];
      };

      crossKernel = crossEval.config.mobile.boot.stage-1.kernel.package;

      # Fix cross-compilation of the kernel.
      #
      # kernel/builder.nix hands the *target* `writeShellScript` to
      # eval-config.nix, so the generated config-validator snippet gets a
      # shebang pointing at aarch64 bash. That script runs on the build host
      # during the kernel's configurePhase, so it dies with
      # "bad interpreter: No such file or directory" (exit 126).
      # `buildPackages` is already in scope there; just use it.
      #
      # This only matters for `pkgsCross` (the kernel); the native `pkgs`
      # instance never cross-compiles, so it never hits this bug.
      mobile-nixos-src = pkgs.applyPatches {
        name = "mobile-nixos-cross-fix";
        src = mobile-nixos;
        postPatch = ''
          substituteInPlace overlay/mobile-nixos/kernel/builder.nix \
            --replace-fail \
              'inherit lib path version writeShellScript;' \
              'inherit lib path version; writeShellScript = buildPackages.writeShellScript;'

          # The taoyao kernel's pmic-glink battery-manager driver
          # (qcom-battmgr-{bat,usb,wls}) refuses synthetic uevents until its
          # RPC channel to the modem/PMIC firmware is up (kernel logs:
          # "failed to send synthetic uevent: -11", i.e. EAGAIN), which is
          # well after stage-1's `udevadm trigger --action=add` runs.
          # System.run() raises on any nonzero exit, so this single trigger
          # failure aborts init with INIT_EXCEPTION before display/mount/
          # switch_root ever happen. Stage-1 doesn't need battery-status
          # devices, so just exclude the power_supply subsystem from the
          # early trigger; stage-2's own udev re-triggers everything once
          # the system (and the glink RPC channel) is fully up.
          substituteInPlace boot/init/tasks/udev.rb \
            --replace-fail \
              'udevadm("trigger", "--action=add")' \
              'udevadm("trigger", "--action=add", "--subsystem-nomatch=power_supply")'

          # This device has no working touchscreen in stage-1 (needs the
          # depmod fix for hid-goodix-spi to autoload, which turned out to
          # destabilize USB -- see git history) and no physical keyboard,
          # so the boot-selection/generation-picker screen would otherwise
          # wait for touch input forever with no way to interact remotely.
          # Auto-continue to the default (first) generation after 15s of
          # no interaction; a real tap within the window still wins, since
          # this only fires from the top-level menu before any navigation.
          substituteInPlace boot/recovery-menu/main.rb \
            --replace-fail \
              '# We need to start somewhere...
BootGUI::MainWindow.instance.present

# And keep the GUI active.
LVGUI.main_loop' \
              '# We need to start somewhere...
BootGUI::MainWindow.instance.present

BOOT_TIMEOUT_DEADLINE = Time.now + 15

LVGUI.main_loop do
  if Time.now >= BOOT_TIMEOUT_DEADLINE
    if File.exist?(::SELECTIONS)
      selections = JSON.parse(File.read(::SELECTIONS))
      first = selections.first
      if first
        File.open("/run/boot/choice", "w") do |file|
          file.write({
            generation: first["id"],
            use_generation_kernel: false,
          }.to_json())
        end
        exit 0
      end
    end
  end
end'
        '';
      };

      device = ./devices/xiaomi-taoyao;

      # Shared by all three DE variants: the base config, debug snapshotting,
      # and the cross-compiled kernel override. `extraModules` is where the
      # DE-specific module(s) go.
      mkEval = extraModules: (import "${mobile-nixos-src}/lib/release-tools.nix" {
        inherit pkgs;
      }).evalWith {
        inherit device;
        modules = [
          ./configuration.nix
          ./modules/debug-snapshot.nix
          # Override the device module's own kernel wiring: use the
          # separately cross-compiled kernel instead of whatever the native
          # `pkgs` would build (which would need to compile the kernel under
          # QEMU emulation -- correct, but very slow).
          ({ lib, ... }: {
            mobile.boot.stage-1.kernel.package = lib.mkForce crossKernel;
          })
        ] ++ extraModules;
      };

      evalPhosh = mkEval [ ./modules/phosh.nix ];
      evalPlasmaMobile = mkEval [ ./modules/plasma-mobile.nix ];
      evalSxmo = mkEval [ (import ./modules/sxmo.nix { sxmoNixSrc = sxmo-nix; }) ];

      # `prefix`-namespaced so all three DE variants' packages can live
      # flat under packages.${buildSystem} (flake checks require every leaf
      # there to be a derivation, not a nested attrset).
      mkPackages = prefix: eval:
        let outputs' = eval.config.mobile.outputs; in {
          # Android boot image (kernel + initrd + appended DTB) for fastboot.
          "${prefix}boot-image" = outputs'.android.android-bootimg;

          # Full rootfs image.
          "${prefix}default" = outputs'.default or outputs'.android.default;

          # Handy for debugging the port.
          "${prefix}device-metadata" = outputs'.device-metadata;
          "${prefix}kernel" = crossKernel;
          "${prefix}firmware" = eval.config.mobile.device.firmware;
        };
    in
    {
      nixosConfigurations = {
        taoyao = evalPhosh;
        taoyao-plasma-mobile = evalPlasmaMobile;
        taoyao-sxmo = evalSxmo;
      };

      packages.${buildSystem} =
        (mkPackages "" evalPhosh)
        // (mkPackages "plasma-mobile-" evalPlasmaMobile)
        // (mkPackages "sxmo-" evalSxmo);

      devShells.${buildSystem}.default = pkgs.mkShell {
        packages = with pkgs; [ android-tools ];
      };
    };
}
