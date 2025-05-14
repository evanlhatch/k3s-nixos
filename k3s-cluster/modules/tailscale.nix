# ./k3s-cluster/modules/tailscale.nix
{
  config,
  lib,
  pkgs,
  specialArgs ? { },
  ...
}:
# This module ensures the Tailscale package is installed and basic firewall rules are set.
# It does NOT enable or configure the tailscaled service directly if K3s is managing
# the Tailscale connection via its --vpn-auth mechanism.
{
  environment.systemPackages = [ pkgs.tailscale ];

  networking.firewall = {
    # If NixOS firewall is active, allow Tailscale's default ports.
    # Note: config.services.tailscale.port is only defined if services.tailscale.enable = true.
    # Hardcoding is safer if services.tailscale is not explicitly enabled by this module.
    allowedUDPPorts = [ 41641 ]; # Default Tailscale port
    # allowedTCPPorts = [ 443 ]; # For DERP over HTTPS if UDP blocked, less common for servers
    trustedInterfaces = [ "tailscale0" ]; # Trust traffic from Tailscale interface
  };

  # If you need to manage tailscaled service independently (e.g., for nodes NOT using K3s vpn-auth):
  # services.tailscale.enable = lib.mkIf (specialArgs.nodeSecretsProvider == "sops" && specialArgs.enableStandaloneTailscale == true) true;
  # services.tailscale.authKeyFile = lib.mkIf (specialArgs.nodeSecretsProvider == "sops" && specialArgs.enableStandaloneTailscale == true) config.sops.secrets.tailscale_authkey.path;
}
