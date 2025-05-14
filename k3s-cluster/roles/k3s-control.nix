# ./k3s-cluster/roles/k3s-control.nix
{
  config,
  lib,
  pkgs,
  specialArgs,
  ...
}:

let
  # Define paths for K3s token and Tailscale auth key using sops-nix
  k3sTokenFile = config.sops.secrets.k3s_token.path;
  tailscaleAuthKeyFile = config.sops.secrets.tailscale_auth_key.path;

  # Control Plane IP should be its own Tailscale IP or a stable private IP known to other nodes.
  # specialArgs.k3sControlPlaneAddr is the IP other nodes use to connect.
  # For --node-ip, we use its own private IP or Tailscale IP.
  nodeIp = specialArgs.nodeIPAddress or specialArgs.k3sControlPlaneAddr; # nodeIPAddress should be specific to this node

in
{
  # Define the K3s server systemd service
  systemd.services.k3s = {
    description = "Lightweight Kubernetes (Server / Control Plane)";
    wantedBy = [ "multi-user.target" ];
    # Must start after network is fully up and secrets (if any) are available
    after = [
      "network-online.target"
      "sops-nix.service"
    ];
    wants = [
      "network-online.target"
      "sops-nix.service"
    ];
    serviceConfig = {
      Type = "notify";
      ExecStart = "${pkgs.k3s}/bin/k3s server"; # Base command
      KillMode = "process";
      Delegate = true;
      LimitNOFILE = 1048576;
      LimitNPROC = "infinity";
      LimitCORE = "infinity";
      TasksMax = "infinity";
      TimeoutStartSec = 0; # K3s handles its own startup timeout logic effectively
      Restart = "always";
      RestartSec = "10s"; # Increased restart delay
    };
  };

  # Configure K3s service
  services.k3s = {
    # This 'enable' flag is typically false for generic images using k3s-role-selector.
    # For a dedicated control-plane node definition in the Flake, set it to true.
    enable = specialArgs.enableK3sServiceByDefault or false;
    role = "server";
    tokenFile = k3sTokenFile; # Use the conditionally defined path

    extraFlags = toString (
      [
        "--node-ip=${nodeIp}" # Use this node's own IP (private or Tailscale)
        "--advertise-address=${nodeIp}" # Advertise this node's IP
        "--bind-address=0.0.0.0" # Listen on all interfaces
        "--kubelet-arg=cloud-provider=external" # For Hetzner CCM
        "--disable-cloud-controller" # We install CCM separately via Flux
        "--disable=servicelb,traefik,local-storage" # Disable built-ins we replace
        # Tailscale CNI integration flags
        "--flannel-backend=none"
        "--disable-network-policy" # If using Tailscale ACLs for network policy
        "--node-external-ip=$(tailscale ip -4)" # Use Tailscale IP for node's external IP concept in K8s
        "--vpn-auth-file=${tailscaleAuthKeyFile}"
        "--vpn-auth-name=k3s-${specialArgs.hostname}" # Unique name for Tailscale device
        # Example: add extra args for --vpn-auth for tags
        # "--vpn-auth-extra-args=--advertise-tags=tag:k3s-control,tag:k3s-cluster-${config.networking.hostName}"
      ]
      ++ (lib.optional (specialArgs.isFirstControlPlane == true) "--cluster-init") # Only for the very first control-plane node
      # Example: Pass datastore endpoint if using external DB for HA
      # ++ (lib.optionals (specialArgs.k3sDatastoreEndpoint != null) [ "--datastore-endpoint=${specialArgs.k3sDatastoreEndpoint}" ])
    );

    # Example config.yaml if needed, though flags are often sufficient for K3s
    # configYAML = pkgs.lib.generators.toYAML {} {
    #   "cluster-cidr" = "10.42.0.0/16"; # Default K3s
    #   "service-cidr" = "10.43.0.0/16"; # Default K3s
    #   # Add other static config.yaml settings here
    # };
  };

  # Firewall rules specific to control-plane
  networking.firewall.allowedTCPPorts = [
    6443 # Kubernetes API Server
    2379 # etcd client (if embedded etcd, for HA)
    2380 # etcd peer (if embedded etcd, for HA)
    10250 # Kubelet (if metrics-server or other components need to reach it directly on control plane)
  ];
  # Tailscale UDP port (41641) should be opened by the tailscale module or base firewall config

  # Essential Kubernetes client tools
  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
    fluxcd # Flux CLI for interacting with the cluster
  ];
}
