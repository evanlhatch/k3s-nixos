# Modified disko layout for thinkcenter-1 with LVM and UEFI-only
{ config, lib, pkgs, ... }:

{
  disko.devices = {
    disk = {
      mainDisk = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            esp = {
              name = "ESP";
              size = "1G";
              type = "EF00"; # EFI System Partition
              content = {
                type = "filesystem";
                format = "vfat";
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
            size = "8G"; # 8GB Swap LV
            content = {
              type = "swap";
            };
          };
        };
      };
    };
  };
}
