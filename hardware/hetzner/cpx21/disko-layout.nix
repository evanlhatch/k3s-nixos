# !k3s-nixos-configs/hardware/hetzner/cpx21/disko-layout.nix
{ lib, pkgs, ... }:
{
  disko.devices = {
    disk = {
      mainDisk = {
        device = "/dev/sda"; # Corrected to /dev/sda for Hetzner CPX21
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            # BIOS Boot Partition (for legacy boot compatibility)
            biosboot = {
              name = "BIOSBOOT";
              size = "1M";
              type = "EF02"; # GRUB BIOS Boot partition type
            };
            # EFI System Partition (ESP)
            esp = {
              name = "ESP";
              size = "1G"; # Increased from 512M to 1G as requested
              type = "EF00"; # EFI System Partition type
              content = {
                type = "filesystem";
                format = "vfat"; # FAT32 for ESP
                mountpoint = "/boot";
              };
            };
            # LVM Physical Volume
            lvm_pv = {
              name = "LVM_PV_MAIN";
              size = "100%"; # Use all remaining space
              content = {
                type = "lvm_pv";
                vg = "vg_main"; # Assign this PV to vg_main
              };
            };
          };
        };
      };
    };
    lvm_vg = {
      vg_main = {
        # Define the Volume Group
        type = "lvm_vg";
        lvs = {
          # Logical Volume for Root Filesystem
          root = {
            name = "lv_root";
            size = "100%FREE"; # All free space in VG
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
              mountOptions = [
                "defaults"
                "discard"
              ]; # Add discard for SSDs if appropriate
            };
          };
          # Logical Volume for Swap
          swap = {
            name = "lv_swap";
            size = "4G"; # 4GB Swap LV
            content = {
              type = "swap";
            };
          };
        };
      };
    };
  };
}
