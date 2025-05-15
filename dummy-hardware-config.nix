# ./dummy-hardware-config.nix
# A minimal, valid NixOS module to satisfy nix flake check when
# /etc/nixos/hardware-configuration.nix is not available during local evaluation.
{
  config,
  pkgs,
  lib,
  modulesPath,
  specialArgs,
  ...
}:

{
  imports = [
    # Importing the generic "not-detected.nix" might be helpful, but sometimes
    # conflicts with other modules. A minimal stub often suffices.
    # (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # Only define options here that are *necessary* for the NixOS module system
  # evaluation to proceed when a real hardware-configuration.nix is missing,
  # and which might not be provided by other modules (like disko or profiles).
  # Use lib.mkDefault for all definitions to ensure they have the lowest priority
  # and do not conflict with real configuration modules.

  # Include common initrd modules that might be required during early boot
  # or by other modules during evaluation. Include LVM related modules as disko uses it.
  boot.initrd.availableKernelModules = lib.mkDefault [
    "ahci"
    "sd_mod"
    "nvme"
    "virtio_blk"
    "usb_storage"
    "uas"
    "ext4"
    "vfat"
    "dm-mod" # Device mapper, needed for LVM
    "lvm2" # LVM tools in initrd
  ];
  # Keep this if `services.lvm.boot.initrd.enable = true;` implicitly expects it, even if empty
  boot.initrd.kernelModules = lib.mkDefault [ ];

  # Bootloader defaults should be defined with mkDefault false
  # to allow real bootloader modules (like systemd-boot or grub) to take precedence.
  boot.loader.grub.enable = lib.mkDefault false;
  boot.loader.systemd-boot.enable = lib.mkDefault false;
  # Keep the device definition if grub.enable was kept, even if false, might satisfy some checks.
  boot.loader.grub.device = lib.mkDefault "/dev/sda";

  # Define hostname with mkDefault, as it will be overridden by specialArgs in flake.nix.
  networking.hostName = lib.mkDefault "dummycheckhost";

  # Set a state version for the dummy config with mkDefault.
  system.stateVersion = lib.mkDefault specialArgs.nixosStateVersion; # <--- Access specialArgs directly}
}
