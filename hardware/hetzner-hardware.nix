{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  # Hetzner Cloud specific hardware configuration

  # Import qemu-guest profile
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  # Hetzner Cloud specific kernel modules
  boot.kernelModules = [
    "virtio_pci"
    "virtio_scsi"
    "nvme"
    "ata_piix"
    "uhci_hcd"
  ];

  # Hetzner Cloud specific boot settings
  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";
    efiSupport = false;
    efiInstallAsRemovable = false;
  };

  # Hetzner Cloud specific filesystem settings
  # Commented out to avoid conflicts with disko
  # fileSystems."/" = lib.mkDefault {
  #   device = "/dev/sda1";
  #   fsType = "ext4";
  # };

  # Hetzner Cloud specific swap settings
  swapDevices = [ ];

  # Enable qemu-guest-agent for Hetzner Cloud
  services.qemuGuest.enable = true;

  # Disable power management
  powerManagement.enable = false;

  # Disable X11
  services.xserver.enable = false;

  # Disable bluetooth
  hardware.bluetooth.enable = false;
}
