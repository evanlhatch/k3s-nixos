# ./dummy-hardware-config.nix
# A minimal, valid NixOS module to satisfy nix flake check when
# /etc/nixos/hardware-configuration.nix is not available during local evaluation.
{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    # You can try to import the generic "not-detected.nix" if you know its store path
    # or have a copy, but often a minimal stub like this is sufficient for checks.
    # Example: (pkgs.path + "/nixos/modules/installer/scan/not-detected.nix") # Path may vary
  ];

  # Provide minimal valid settings to make this a functional module for evaluation.
  # These settings are primarily for allowing `nix flake check` to pass purely
  # and will NOT be used for actual deployments with nixos-anywhere if you are using "Option A"
  # (where the installer generates the real /etc/nixos/hardware-configuration.nix).

  boot.initrd.availableKernelModules = [
    "ahci" # Common SATA controller
    "sd_mod" # SCSI disk support (often needed for virtio-scsi)
    "nvme" # NVMe disk support
    "virtio_blk" # VirtIO block device (common in VMs)
    "usb_storage" # For USB devices
    "uas" # USB Attached SCSI
    # Add other common filesystem or bus modules if your checks go deep
    "ext4"
    "vfat"
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_DUMMY_ROOT"; # A non-existent device for dummy purposes
    fsType = "ext4";
  };

  # A dummy /boot is often needed if a bootloader is enabled/checked
  fileSystems."/boot" =
    lib.mkIf (config.boot.loader.grub.enable || config.boot.loader.systemd-boot.enable)
      {
        device = "/dev/disk/by-label/NIXOS_DUMMY_BOOT"; # Dummy boot partition
        fsType = "vfat";
      };

  swapDevices = [
    # { device = "/dev/disk/by-label/NIXOS_DUMMY_SWAP"; } # Dummy swap
  ];

  # Ensure a bootloader is configured if your dummy config needs to evaluate that far.
  # For basic flake checks, this might not be strictly necessary if no other module
  # asserts on bootloader settings.
  boot.loader.grub.enable = lib.mkDefault true; # Or systemd-boot
  boot.loader.grub.device = lib.mkDefault "/dev/sda"; # Dummy device for grub install (won't actually run)

  # This is important if your other modules try to reference networking.hostName during evaluation.
  # It will be overridden by the actual hostname from specialArgs in a real build.
  networking.hostName = lib.mkDefault "dummycheckhost";

  # Set a state version for the dummy config as well.
  system.stateVersion = lib.mkDefault config.specialArgs.nixosStateVersion;
}
