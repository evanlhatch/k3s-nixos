{
  config,
  lib,
  pkgs,
  ...
}:

{
  disko.devices = {
    disk = {
      mainDisk = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              name = "ESP";
              size = "1G";
              type = "EF00"; # EFI System Partition
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            swap = {
              name = "swap";
              size = "8G";
              content = {
                type = "swap";
                randomEncryption = false;
              };
            };
            root = {
              name = "NIXOS_ROOT";
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
