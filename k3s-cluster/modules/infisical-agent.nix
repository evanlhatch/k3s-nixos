# k3s-cluster/modules/infisical-agent.nix
{
  config,
  lib,
  pkgs,
  specialArgs ? { },
  ...
}:

let
  # Get the Infisical address from sops-nix decrypted file content
  # Ensure 'infisical_address' is defined in sops.secrets in commonSopsModule
  infisicalAddress = builtins.readFile (config.sops.secrets.infisical_address.path);

  # Get paths to client ID and secret files, also managed by sops-nix
  # Ensure 'infisical_client_id' and 'infisical_client_secret' are defined in sops.secrets
  infisicalClientIdPath = config.sops.secrets.infisical_client_id.path;
  infisicalClientSecretPath = config.sops.secrets.infisical_client_secret.path;

  # Check if the agent should be enabled (passed via specialArgs from flake.nix)
  enableAgent = specialArgs.enableInfisicalAgent or false;
in
lib.mkIf enableAgent {
  environment.systemPackages = [ pkgs.infisical ];

  # sops-nix creates the secret files. We just need to ensure the agent's config dir exists.
  systemd.tmpfiles.rules = [
    "d /etc/infisical 0750 root root - -" # For agent.yaml
    "d /run/infisical-secrets 0750 root root - -" # For rendered secrets by agent
  ];

  environment.etc."infisical/agent.yaml" = {
    mode = "0400"; # Readable only by root
    text = ''
      infisical:
        address: "${infisicalAddress}" # Content read from sops-decrypted file
      auth:
        type: "universal-auth"
        config:
          client-id_file: ${infisicalClientIdPath}        # Path to sops-decrypted file
          client-secret_file: ${infisicalClientSecretPath} # Path to sops-decrypted file
          # remove_client_secret_on_read: true # Consider for enhanced security

      templates:
        - destination_path: /run/infisical-secrets/k3s_token
          template_content: |
            {{ secret "/k3s-bootstrap" "K3S_TOKEN" }}
          config:
            permissions: "0400"
        - destination_path: /run/infisical-secrets/tailscale_join_key
          template_content: |
            {{ secret "/k3s-bootstrap" "TAILSCALE_AUTH_KEY" }}
          config:
            permissions: "0400"
    '';
  };

  systemd.services.infisical-agent = {
    description = "Infisical Agent Daemon";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "sops-secrets.service" # Ensure sops secrets (like client_id file) are ready
    ];
    wants = [
      "network-online.target"
      "sops-secrets.service"
    ];
    before = [
      "k3s.service"
      "k3s-agent.service"
    ];
    serviceConfig = {
      Type = "simple";
      ExecStart = ''
        ${pkgs.infisical}/bin/infisical-agent --config /etc/infisical/agent.yaml daemon start
      '';
      Restart = "on-failure";
      RestartSec = "10s";
      User = "root"; # Assuming agent needs root to write to /run/infisical-secrets
    };
  };
}
