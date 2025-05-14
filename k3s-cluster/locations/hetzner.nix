# ./k3s-cluster/locations/hetzner.nix
{
  config,
  lib,
  pkgs,
  specialArgs,
  ...
}:
{
  # Enable qemuGuest service directly instead of importing the module
  imports = [ ];

  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "nvme"
    "xhci_pci"
    "sr_mod"
    "ata_piix"
    "uhci_hcd"
  ];
  boot.kernelModules = [ "virtio_net" ]; # Important for Hetzner networking

  # systemd-networkd is enabled by profiles/base-server.nix.
  # This configures the standard Hetzner interfaces.
  systemd.network.networks = {
    "10-public" = {
      matchConfig.Name = specialArgs.hetznerPublicInterface or "eth0";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = true;
      };
    };
    "20-private" =
      lib.mkIf (specialArgs.hetznerPrivateInterface != null && specialArgs.hetznerPrivateInterface != "")
        {
          matchConfig.Name = specialArgs.hetznerPrivateInterface;
          networkConfig = {
            DHCP = "ipv4";
          }; # Usually gets IP from Hetzner private net DHCP
          linkConfig.RequiredForOnline = "no";
        };
  };

  # DO NOT force fileSystems."/" or boot.loader here.
  # Let it be defined by the auto-generated hardware-configuration.nix (for nixos-everywhere)
  # or by a disko configuration (for image builds).

  services.cloud-init = {
    enable = true;
    # Let systemd-networkd handle actual network config based on definitions above.
    # Cloud-init primarily for user-data (ssh keys, role file).
    network.enable = false;
  };
  services.qemuGuest.enable = true;
  time.timeZone = lib.mkDefault "Etc/UTC"; # Servers should be UTC
}
