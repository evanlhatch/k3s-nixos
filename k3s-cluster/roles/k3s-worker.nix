# ./roles/k3s-worker.nix (Illustrative, apply similar logic to k3s-control.nix)
{
  config,
  lib,
  pkgs,
  specialArgs,
  ...
}:
let
  # isInfisical = specialArgs.nodeSecretsProvider == "infisical"; # Removed

  k3sTokenFile = "/run/infisical-secrets/k3s_token"; # Changed
  # if isInfisical then "/run/infisical-secrets/k3s_token" else config.sops.secrets.k3s_token.path; # Assumes 'k3s_token' is the sops secret name

  tailscaleAuthKeyFile = "/run/infisical-secrets/tailscale_join_key"; # Changed
  # if isInfisical then
  #   "/run/infisical-secrets/tailscale_join_key"
  # else
  #   config.sops.secrets.tailscale_authkey.path; # Assumes 'tailscale_authkey' is sops name
in
{
  # K3s Agent Service Definition (should be in systemd.services for clarity)
  systemd.services.k3s-agent = {
    description = "Lightweight Kubernetes (Agent)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "infisical-agent.service"
    ];
    wants = [
      "network-online.target"
      "infisical-agent.service"
    ];
    serviceConfig = {
      Type = "notify";
      ExecStart = "${pkgs.k3s}/bin/k3s agent";
      # ... other serviceConfig options from your plan ...
      Restart = "always";
      RestartSec = "10s";
    };
  };

  services.k3s = {
    # This enable flag is controlled by the k3s-role-selector service in generic images,
    # or can be set to `true` directly in a specific Flake nixosConfiguration for a dedicated node.
    enable = false;
    role = "agent";
    # Use the control plane address passed via specialArgs
    serverAddr = "https://${specialArgs.k3sControlPlaneAddr}:6443";
    tokenFile = k3sTokenFile; # Dynamically set path
    extraFlags = toString ([
      "--kubelet-arg=cloud-provider=external" # For Hetzner CCM
      # K3s with Tailscale CNI integration flags
      "--flannel-backend=none"
      "--disable-network-policy" # Tailscale ACLs manage policy
      # Following flags require Tailscale to be up and accessible.
      # K3s --vpn-auth should handle bringing Tailscale up.
      "--node-external-ip=$(tailscale ip -4)" # Use node's Tailscale IP
      "--vpn-auth-file=${tailscaleAuthKeyFile}" # Use the key provided by Infisical/Sops
      "--vpn-auth-name=k3s-${specialArgs.hostname}" # Unique name for the Tailscale VPN device
      # Add other node labels or taints as needed, possibly from specialArgs
      # e.g., "--node-label=role=${specialArgs.role}"
    ]
    # Example of adding custom taints from specialArgs
    # ++ (lib.mapAttrsToList (name: value: "--node-taint=${name}=${value}:NoSchedule") (specialArgs.nodeTaints or {}))
    );
  };

  # Worker-specific firewall rules (K3s CNI might manage some itself)
  networking.firewall.allowedTCPPorts = [ 10250 ]; # Kubelet API
  # Tailscale UDP port is handled by the tailscale module or base firewall.

  environment.systemPackages = with pkgs; [ kubectl ]; # For debugging
}
