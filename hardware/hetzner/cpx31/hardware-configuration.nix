{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
  boot.loader.grub = {
    enable = true;
    devices = [ "/dev/sda" ];
    efiSupport = false;
  };
  boot.initrd.availableKernelModules = [
    "ata_piix"
    "uhci_hcd"
    "xen_blkfront"
    "vmw_pvscsi"
  ];
  boot.initrd.kernelModules = [ "nvme" ];
  # Commented out to avoid conflicts with disko
  # fileSystems."/" = {
  #   device = "/dev/sda1";
  #   fsType = "ext4";
  # };

  # CPX31 specs: 4 cores, 8GB RAM, 160GB disk
}
