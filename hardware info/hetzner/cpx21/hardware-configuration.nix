{ modulesPath, lib, ... }:
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  # == Settings Previously in configuration.nix ==
  # Basic hardware configuration
  boot.initrd.availableKernelModules = [
    "ata_piix"
    "uhci_hcd"
    "xen_blkfront"
    "vmw_pvscsi"
    "virtio_blk"
    "virtio_pci"
  ];
  boot.initrd.kernelModules = [
    "nvme"
    "virtio_blk"
  ];

  # Hetzner-specific settings
  services.qemuGuest.enable = true;

  # CPX21 specs: 3 cores, 4GB RAM, 80GB disk
  nix.settings.max-jobs = lib.mkDefault 3;
  # == End Settings Previously in configuration.nix ==

  # Boot loader configuration
  boot.loader.grub = {
    # Explicitly set devices to ensure GRUB is installed to the MBR of /dev/sda
    devices = [ "/dev/sda" ];
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  # Note: Don't set fileSystems here as disko will handle that
  # The previous setting is removed as it conflicts with disko:
  # fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };

  # CPX21 specs: 3 cores, 4GB RAM, 80GB disk
}
