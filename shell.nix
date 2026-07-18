{ pkgs ? import <nixpkgs> { } }:

let
  cross = pkgs.pkgsCross.aarch64-multiplatform;
in
pkgs.mkShell {
  name = "taoyao-pmos";

  packages = with pkgs; [
    pmbootstrap   # build/flash postmarketOS
    git           # pmaports + kernel source checkout
    android-tools # fastboot/adb, also pulls in mkbootimg/unpackbootimg
    abootimg      # inspect/unpack/repack the stock boot.img
    dtc           # device tree compiler, also decompiles the stock dtb
    openssh       # pmbootstrap --ssh deploy

    # downstream (taoyao-s-oss, linux 5.4) kernel build
    clang         # ACK build.config.common pins CC=clang
    lld           # LLVM linker, matches clang toolchain
    llvmPackages.bintools # llvm-{nm,objcopy,strip,ar}
    cross.buildPackages.binutils # GNU aarch64 `as`: modern clang's integrated
                                  # assembler mishandles this kernel's old LSE
                                  # atomics inline asm, so build with LLVM_IAS=0
    bc
    bison
    flex
    openssl
    elfutils      # libelf for CONFIG_STACK_VALIDATION
    ncurses       # menuconfig
    python3
    perl
    cpio
    kmod
  ];

  ARCH = "arm64";
}
