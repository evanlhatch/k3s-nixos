# ./flake.nix
{
  description = "NixOS K3s Cluster Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Flake-utils for simplified system-specific outputs
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # nixos-anywhere input is for the devShell, not direct flake use by system configs
    nixos-anywhere = {
      url = "github:numtide/nixos-anywhere"; # Assuming this was your original intent for devShell
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      # Added sops-nix input
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      deploy-rs,
      disko,
      sops-nix,
      nixos-anywhere,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      sopsSecrets = pkgs.lib.file // {
        name = "sops.secrets.yaml";
        path = ./sops.secrets.yaml; # Assuming your sops.secrets.yaml is in the same directory as flake.nix
      };

      commonSopsModule =
        {
          config,
          pkgs,
          lib,
          ...
        }:
        {
          # 1. Configure AGE Key File (to be deployed by nixos-anywhere/mage)
          #    This path is where nixos-anywhere (via mage) will place the AGE key.
          sops.age.keyFile = "/etc/sops/age/key.txt"; # Ensure this dir/file is writable during initial setup or use /var/lib/sops
          sops.age.generateKey = false; # We provide the key

          # Disable validation of sops files during development
          sops.validateSopsFiles = false; # Important for development, secrets will be on deployed machines

          # 2. Define all secrets sops-nix should manage and make available as files
          #    These files will typically be created in /run/secrets/
          sops.secrets.infisical_client_id = {
            # Path can be omitted to use default /run/secrets/infisical_client_id
            # mode = "0400"; # Default is usually fine
            # owner = config.users.users.root.name; # Or specific user for infisical agent if not root
          };
          sops.secrets.infisical_client_secret = { };
          sops.secrets.infisical_address = { };

          # If K3S_TOKEN and TAILSCALE_AUTH_KEY are ONLY ever provisioned by Infisical agent
          # then you don't need to define them here for sops-nix to create files for them.
          # However, if some nodes might need them directly from sops (e.g., before Infisical agent is up,
          # or for Infisical agent's own config if it needed to login to Tailscale itself first),
          # you could define them here. For now, we assume Infisical agent fetches them.
          # sops.secrets.k3s_token_from_sops = { neededForUsers = false; };
          # sops.secrets.tailscale_authkey_from_sops = { neededForUsers = false; };

          # 3. Ensure the encrypted sops file itself is deployed to the target
          #    sops-nix will read this file on the target using the deployed AGE key.
          sops.defaultSopsFile = "/etc/nixos/secrets.sops.yaml"; # The path where the sops file will be stored

          system.activationScripts.deploySopsFile = lib.mkIf (config.sops.defaultSopsFile != null) {
            text = ''
              echo "Copying encrypted sops file to target system..."
              mkdir -p "$(dirname "${config.sops.defaultSopsFile}")"
              # The source ./sops.secrets.yaml is relative to the flake root
              cp ${./sops.secrets.yaml} "${config.sops.defaultSopsFile}"
              chmod 0400 "${config.sops.defaultSopsFile}" # Restrict permissions
              echo "Encrypted sops file deployed to ${config.sops.defaultSopsFile}"
            '';
            deps = [ "users" ]; # Run after users are set up, before services typically start
          };

          # Ensure the directory for the AGE key exists and has correct permissions
          # This might be better handled by nixos-anywhere ensuring the path it copies to exists.
          systemd.tmpfiles.rules = [
            "d /etc/sops/age 0700 root root -" # Directory for AGE key
          ];
        };

    in
    let
      # Helper function for environment variables with defaults
      getEnv =
        name: defaultValue:
        let
          value = builtins.getEnv name;
        in
        if value == "" then defaultValue else value;

      # Helper function to create a state version module
      stateVersionModule =
        version:
        { lib, ... }:
        {
          system.stateVersion = version;
        };

      # Common node arguments from environment
      commonNodeArgumentsFromEnv = {
        k3sControlPlaneAddr = "https://control-plane.example.com:6443";
        adminUsername = "nixos";
        adminSshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...";
        nixosStateVersion = "25.05";
      };

      # Helper function for creating NixOS systems
      mkNixosSystem =
        {
          rolePath,
          locationProfilePath,
          machineHardwareConfigPath ? null,
          extraModules ? [ ],
          specialArgsOverride ? { },
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops # Main sops-nix module
            commonSopsModule # Our sops configurations (key, secret definitions)
            ./k3s-cluster/profiles/base-server.nix # Imports the consolidated infisical module
            rolePath
            locationProfilePath
            inputs.disko.nixosModules.disko
            (pkgs.lib.mkIf (specialArgsOverride ? location && specialArgsOverride.location == "hetzner") ./disko-configs/hetzner-disko-layout.nix)
            (pkgs.lib.mkIf (specialArgsOverride ? location && specialArgsOverride.location == "local") ./disko-configs/generic-disko-layout.nix)
            (pkgs.lib.mkIf (machineHardwareConfigPath != null) machineHardwareConfigPath)
          ] ++ extraModules;
          specialArgs = {
            # ... remove config.sops.secrets access ... #
            # Common arguments for all nodes
            # inherit (commonNodeArgumentsFromEnv)
            #   k3sControlPlaneAddr
            #   adminUsername
            #   adminSshPublicKey
            #   nixosStateVersion;

            # Default network interface settings
            hetznerPublicInterface = "eth0";
            hetznerPrivateInterface = "ens10";

            # Override with any specific arguments for this node
          } // specialArgsOverride;
        };
    in
    {
      # NixOS configurations for different node types
      nixosConfigurations = {
        # === ARCHETYPE TEMPLATES for nixos-anywhere (currently all x86_64-linux) ===
        "thinkcenter-1" = mkNixosSystem {
          rolePath = ./k3s-cluster/roles/k3s-control.nix;
          locationProfilePath = ./k3s-cluster/locations/local.nix;
          extraModules = [
            (stateVersionModule "24.11")
          ];
          specialArgsOverride = {
            hostname = "thinkcenter-1";
            isFirstControlPlane = true;
            location = "local";
          };
        };

        "hetzner-control-plane" = mkNixosSystem {
          rolePath = ./k3s-cluster/roles/k3s-control.nix;
          locationProfilePath = ./k3s-cluster/locations/hetzner.nix;
          machineHardwareConfigPath = ./hardware/hetzner-hardware.nix; # Generic Hetzner hardware defaults
          specialArgsOverride = {
            hostname = getEnv "NODE_HOSTNAME" "k3s-hcloud-cp";
            isFirstControlPlane = (getEnv "IS_FIRST_CONTROL_PLANE" "true") == "true";
            location = "hetzner";
          };
        };

        # NEW: Specific archetype for Hetzner CPX21 Control Plane
        "hetzner-cpx21-control-plane-archetype" = mkNixosSystem {
          rolePath = ./k3s-cluster/roles/k3s-control.nix;
          locationProfilePath = ./k3s-cluster/locations/hetzner.nix;
          #machineHardwareConfigPath = ./hardware/hetzner/cpx21/hardware-configuration.nix; # Use the specific cpx21 hardware config
          extraModules = [
            (stateVersionModule "25.05")
          ];
          specialArgsOverride = {
            hostname = getEnv "NODE_HOSTNAME" "k3s-cpx21-cp"; # Hostname template for CPX21 CP
            isFirstControlPlane = (getEnv "IS_FIRST_CONTROL_PLANE" "true") == "true";
            location = "hetzner";
          };
        };

        "hetzner-worker" = mkNixosSystem {
          rolePath = ./k3s-cluster/roles/k3s-worker.nix;
          locationProfilePath = ./k3s-cluster/locations/hetzner.nix;
          #machineHardwareConfigPath = ./hardware/hetzner-hardware.nix; # Generic Hetzner hardware defaults
          specialArgsOverride = {
            hostname = getEnv "NODE_HOSTNAME" "k3s-hcloud-worker";
            isFirstControlPlane = false; # Workers are never first control plane
            location = "hetzner";
          };
        };

        # === ACTUAL DEPLOYED MACHINES (not archetypes) ===
        # Assumes ./machines/hetzner/my-hcloud-control01/hardware-configuration.nix will be created post-provisioning
        "my-hcloud-control01" = mkNixosSystem {
          rolePath = ./k3s-cluster/roles/k3s-control.nix;
          locationProfilePath = ./k3s-cluster/locations/hetzner.nix;
          #machineHardwareConfigPath = ./hardware/hetzner/cpx31/hardware-configuration.nix; # Updated to new path
          extraModules = [
            (stateVersionModule "25.05")
          ];
          specialArgsOverride = {
            hostname = "my-hcloud-control01";
            isFirstControlPlane = true;
            location = "hetzner";
          };
        };

        # Add our cpx21-control-1 configuration
        "cpx21-control-1" = mkNixosSystem {
          rolePath = ./k3s-cluster/roles/k3s-control.nix;
          locationProfilePath = ./k3s-cluster/locations/hetzner.nix;
          #machineHardwareConfigPath = ./hardware/hetzner/cpx21/hardware-configuration.nix;
          extraModules = [
            (stateVersionModule "25.05")
            {
              sops.secrets.k3s_token = {
                path = "/etc/nixos/secrets.yaml";
                format = "yaml";
                name = "k3sToken";
              };
              sops.secrets.tailscale_auth_key = {
                path = "/etc/nixos/secrets.yaml";
                format = "yaml";
                name = "tailscaleAuthKey";
              };

              # Deploy the SOPS secrets file
              system.activationScripts.deploySecrets = {
                deps = [ "users" ]; # Run after users are set up
                text = ''
                  mkdir -p /etc/nixos
                  # This assumes the secrets file is already present, e.g., deployed by deploy-rs
                  # If not, you'll need to add a deployment step to copy the file
                  # For example:
                  # cp /path/to/your/sops.secrets.yaml /etc/nixos/secrets.yaml
                  echo "SOPS secrets file deployed to /etc/nixos/secrets.yaml"
                '';
              };
            }
          ];
          specialArgsOverride = {
            hostname = "cpx21-control-1";
            isFirstControlPlane = true;
            hetznerPublicInterface = "eth0";
            hetznerPrivateInterface = "ens10";
            enableInfisicalAgent = true; # This will be used by the module
            location = "hetzner";
          };
        };
      }; # End nixosConfigurations

      deploy.nodes = {
        # Example node - not used in actual deployment
        "thinkcenter-1" = {
          hostname = "100.108.23.65"; # From your tailscale status
          sshUser = "evanlhatch"; # From your tailscale status
          fastConnection = true;
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.${system}.activate.nixos self.nixosConfigurations."thinkcenter-1";
          };
        };

        "my-hcloud-control01" = {
          hostname = "my-hcloud-control01"; # Use the hostname directly
          sshUser = "root";
          fastConnection = true;
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.${system}.activate.nixos self.nixosConfigurations."my-hcloud-control01";
          };
        };

        # Add our cpx21-control-1 deploy node
        "cpx21-control-1" = {
          hostname = "5.161.241.28"; # Use the IP address directly
          sshUser = "root";
          fastConnection = true;
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.${system}.activate.nixos self.nixosConfigurations."cpx21-control-1";
          };
        };
        # Add other deploy-rs managed nodes here, pointing to their specific nixosConfiguration
      };

      packages.x86_64-linux =
        let
          pkgs = nixpkgs.legacyPackages.${system};

          buildDiskImage =
            imageName: nixosConfigName: format: diskSize:
            pkgs.callPackage (nixpkgs + "/nixos/lib/make-disk-image.nix") {
              name = imageName;
              inherit format diskSize;
              config = self.nixosConfigurations."${nixosConfigName}".config;
              inherit pkgs;
            };

          # Create simple wrapper scripts for mage commands
          mageWrappers =
            pkgs.runCommand "mage-wrappers"
              {
                buildInputs = [ pkgs.makeWrapper ];
              }
              ''
                mkdir -p $out/bin

                # Create the main mage wrapper
                makeWrapper ${pkgs.mage}/bin/mage $out/bin/mage \
                  --set PATH ${
                    pkgs.lib.makeBinPath [
                      pkgs.mage
                      pkgs.go
                      pkgs.hcloud
                      pkgs.kubectl
                      pkgs.kubernetes-helm
                      pkgs.fluxcd
                      pkgs.tailscale
                      deploy-rs.packages.${system}.deploy-rs
                      nixos-anywhere.packages.${system}.default
                      disko.packages.${system}.disko
                    ]
                  } \
                  --run "cd ${builtins.toString ./.}"

                # Create wrappers for specific mage targets
                for target in recreateNode deploy recreateServer deleteAndRedeployServer; do
                  makeWrapper ${pkgs.mage}/bin/mage $out/bin/mage-$target \
                    --set PATH ${
                      pkgs.lib.makeBinPath [
                        pkgs.mage
                        pkgs.go
                        pkgs.hcloud
                        pkgs.kubectl
                        pkgs.kubernetes-helm
                        pkgs.fluxcd
                        pkgs.tailscale
                        deploy-rs.packages.${system}.deploy-rs
                        nixos-anywhere.packages.${system}.default
                        disko.packages.${system}.disko
                      ]
                    } \
                    --run "cd ${builtins.toString ./.}" \
                    --add-flags "$target"
                done
              '';
        in
        {
          hetznerK3sWorkerRawImage =
            buildDiskImage "hetzner-k3s-worker-image" "hetzner-worker" # Uses the "hetzner-worker" archetype
              "raw"
              "10G";

          hetznerK3sControlRawImage =
            buildDiskImage "hetzner-k3s-control-image" "hetzner-control-plane" # Uses the "hetzner-control-plane" archetype
              "raw"
              "10G";

          # Export our mage wrappers
          inherit mageWrappers;
        };

      # Add apps to make it easy to run the mage commands
      apps.x86_64-linux =
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          # Main mage command
          mage = {
            type = "app";
            program = "${self.packages.x86_64-linux.mageWrappers}/bin/mage";
          };

          # Specific mage commands as apps
          recreateNode = {
            type = "app";
            program = "${self.packages.x86_64-linux.mageWrappers}/bin/mage-recreateNode";
          };

          deploy = {
            type = "app";
            program = "${self.packages.x86_64-linux.mageWrappers}/bin/mage-deploy";
          };

          recreateServer = {
            type = "app";
            program = "${self.packages.x86_64-linux.mageWrappers}/bin/mage-recreateServer";
          };

          deleteAndRedeployServer = {
            type = "app";
            program = "${self.packages.x86_64-linux.mageWrappers}/bin/mage-deleteAndRedeployServer";
          };

          # Default app
          default = self.apps.x86_64-linux.mage;
        };

      # Define devShells directly for x86_64-linux
      devShells.x86_64-linux =
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            buildInputs = [
              pkgs.just
              pkgs.hcloud
              pkgs.kubectl
              pkgs.kubernetes-helm
              pkgs.fluxcd
              pkgs.tailscale
              deploy-rs.packages.${system}.deploy-rs
              nixos-anywhere.packages.${system}.default # Add nixos-anywhere to devShell
              disko.packages.${system}.disko # Add disko to devShell
              pkgs.mage # Add mage
              pkgs.go
              pkgs.gotools
              pkgs.gopls
            ];

            shellHook = ''
              echo "---"
              echo "Ensure .env is populated."
              echo "Available mage commands:"
              mage -l 2>/dev/null || echo "mage not installed or no targets defined."
              echo "Available just commands:"
              just -l 2>/dev/null || echo "justfile not found or just not installed."
              echo "---"
            '';
          };
        };

      # Add checks for deploy-rs
    };
}
