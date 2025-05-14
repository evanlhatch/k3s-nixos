{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
  # Boot loader configuration is in flake.nix
  boot.initrd.availableKernelModules = [
    "ata_piix"
    "uhci_hcd"
    "xen_blkfront"
    "vmw_pvscsi"
  ];
  boot.initrd.kernelModules = [ "nvme" ];
  # Root filesystem is managed by disko using LVM
  # fileSystems."/" = {
  #   device = "/dev/vg_main/lv_root";
  #   fsType = "ext4";
  # };

  # CPX21 specs: 3 cores, 4GB RAM, 80GB disk
}
