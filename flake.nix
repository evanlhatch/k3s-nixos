# ./flake.nix
{
  description = "NixOS K3s Cluster Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-anywhere = {
      url = "github:numtide/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs"; # Keep follows for consistency
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-facter-modules = {
      url = "github:nix-community/nixos-facter-modules";
      # Removed: inputs.nixpkgs.follows = "nixpkgs"; # <-- Removed this line to fix the warning
    };
    # Add the nixos-facter CLI tool as a separate input
    nixos-facter-cli = {
      url = "github:numtide/nixos-facter";
      inputs.nixpkgs.follows = "nixpkgs"; # Keep follows for consistency
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      deploy-rs,
      disko,
      sops-nix,
      nixos-facter-modules,
      nixos-facter-cli,
      nixos-anywhere, # Explicitly list nixos-anywhere here
      ...
    }@inputs:
    let
      # Explicitly inherit all inputs used within this let block
      inherit (inputs)
        self
        nixpkgs
        deploy-rs
        disko
        sops-nix
        nixos-facter-modules
        nixos-facter-cli
        nixos-anywhere # Inherit nixos-anywhere
        ;

      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib;

      getEnv =
        name: defaultValue:
        let
          value = builtins.getEnv name;
        in
        if value == "" then defaultValue else value;
      stateVersionModule =
        version:
        { ... }:
        {
          system.stateVersion = lib.mkDefault version;
        };

      commonSopsModule =
        {
          config,
          pkgs,
          lib,
          ...
        }:
        {
          sops.age.keyFile = "/etc/sops/age/key.txt";
          sops.age.generateKey = false;
          sops.validateSopsFiles = false;
          sops.secrets.infisical_client_id = { };
          sops.secrets.infisical_client_secret = { };
          sops.secrets.infisical_address = { };
          sops.secrets.K3S_CLUSTER_JOIN_TOKEN = { };
          sops.secrets.TAILSCALE_PROVISION_KEY = { };
          sops.defaultSopsFile = "/etc/nixos/secrets.sops.yaml";
          system.activationScripts.deploySopsFile =
            lib.mkIf (config.sops.defaultSopsFile != null && builtins.pathExists ./sops.secrets.yaml)
              {
                text = ''
                  echo "Copying encrypted sops file to target system..."
                  mkdir -p "$(dirname "${config.sops.defaultSopsFile}")"
                  cp ${./sops.secrets.yaml} "${config.sops.defaultSopsFile}"
                  chmod 0400 "${config.sops.defaultSopsFile}"
                  echo "Encrypted sops file deployed to ${config.sops.defaultSopsFile}"
                '';
                deps = [ "users" ];
              };
          systemd.tmpfiles.rules = [ "d /etc/sops/age 0700 root root -" ];
        };

      commonNodeArguments = {
        k3sControlPlaneAddr = getEnv "K3S_CONTROL_PLANE_ADDR" "https_REPLACE_ME_K3S_API_ENDPOINT_6443";
        adminUsername = getEnv "ADMIN_USERNAME" "nixos_admin";
        adminSshPublicKey = getEnv "ADMIN_SSH_PUBLIC_KEY" "ssh-ed25519 REPLACE_ME_WITH_YOUR_PUBLIC_KEY";
        nixosStateVersion = getEnv "NIXOS_STATE_VERSION" "25.05";
        hetznerPublicInterface = getEnv "HETZNER_PUBLIC_INTERFACE" "eth0";
        hetznerPrivateInterface = getEnv "HETZNER_PRIVATE_INTERFACE" "ens10";
      };

      rolePathMappings = {
        control = ./k3s-cluster/roles/k3s-control.nix;
        worker = ./k3s-cluster/roles/k3s-worker.nix;
      };
      locationProfilePathMappings = {
        hetzner = ./k3s-cluster/locations/hetzner.nix;
        local = ./k3s-cluster/locations/local.nix;
      };
      diskoConfigPathMappings = {
        hetzner = ./disko-configs/hetzner-disko-layout.nix;
        local = ./disko-configs/generic-disko-layout.nix;
      };

      dummyHardwareConfigPath = ./dummy-hardware-config.nix; # Ensure this file exists

      mkNixosSystem =
        {
          derivedRolePath,
          derivedLocationProfilePath,
          derivedDiskoConfigPath,
          hardwareConfigModulePath,
          extraModules ? [ ],
          specialArgsResolved,
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
            commonSopsModule
            ./k3s-cluster/profiles/base-server.nix
            derivedRolePath
            derivedLocationProfilePath
            inputs.disko.nixosModules.disko
            derivedDiskoConfigPath
            (stateVersionModule specialArgsResolved.nixosStateVersion)
            hardwareConfigModulePath
            # If you intend to use the nixos-facter NixOS module, add it here:
            # inputs.nixos-facter-modules.nixosModules.facter
          ] ++ extraModules;
          specialArgs = specialArgsResolved;
        };

      privateMachinesPath = ./machines.nix;
      allMachinesData =
        if builtins.pathExists privateMachinesPath then
          (import privateMachinesPath {
            inherit
              lib
              pkgs
              getEnv
              stateVersionModule
              ;
          })
        else
          {
            "example-node" = {
              location = "local";
              nodeType = "control-init";
              _hardwareConfigModulePath_override = dummyHardwareConfigPath;
              deploy = {
                sshHostname = "localhost";
                sshUser = getEnv "USER" "nixos";
              };
            };
          };

    in
    {
      nixosConfigurations = lib.mapAttrs (
        name: machineData:
        let
          roleKey = if machineData.nodeType == "worker" then "worker" else "control";
          # Corrected line: removed the stray 'example' and ensured 'or (throw ...)' is applied correctly
          finalRolePath =
            rolePathMappings.${roleKey}
              or (throw "Invalid role derived from nodeType: '${machineData.nodeType}' for machine '${name}'. Must be 'control-init/join' or 'worker'.");

          finalLocationProfilePath =
            locationProfilePathMappings.${machineData.location}
              or (throw "Invalid location: '${machineData.location}' for machine '${name}'. Must be 'hetzner' or 'local'.");

          finalDiskoConfigPath =
            diskoConfigPathMappings.${machineData.location}
              or (throw "No disko config mapping for location: '${machineData.location}' for machine '${name}'.");

          isFirstCp = (machineData.nodeType == "control-init");

          resolvedSpecialArgs =
            commonNodeArguments
            // {
              location = machineData.location;
              isFirstControlPlane = isFirstCp;
            }
            // {
              hostname = name;
            };

          finalHardwareConfigModulePath =
            machineData._hardwareConfigModulePath_override or /etc/nixos/hardware-configuration.nix;

        in
        mkNixosSystem {
          derivedRolePath = finalRolePath;
          derivedLocationProfilePath = finalLocationProfilePath;
          derivedDiskoConfigPath = finalDiskoConfigPath;
          hardwareConfigModulePath = finalHardwareConfigModulePath;
          extraModules = machineData.extraModules or [ ];
          specialArgsResolved = resolvedSpecialArgs;
        }
      ) allMachinesData;

      deploy.nodes = lib.mapAttrs (
        name: machineData:
        if !(machineData ? deploy) then
          null
        else
          {
            inherit (machineData.deploy) sshHostname sshUser;
            fastConnection = machineData.deploy.fastConnection or true;
            profiles.system = {
              user = machineData.deploy.activationUser or "root";
              path = deploy-rs.lib.${system}.activate.nixos self.nixosConfigurations."${name}";
            };
          }
      ) (lib.filterAttrs (name: data: data != null && data ? deploy) allMachinesData);

      packages.${system} =
        let
          mageEnvPath = lib.makeBinPath [
            pkgs.mage
            pkgs.go
            pkgs.hcloud
            pkgs.kubectl
            pkgs.kubernetes-helm
            pkgs.fluxcd
            pkgs.tailscale
            deploy-rs.packages.${system}.deploy-rs
            nixos-anywhere.packages.${system}.default
            inputs.nixos-facter-cli.packages.${system}.default # <-- Corrected: Reference 'default' package from the new 'nixos-facter-cli' input
            disko.packages.${system}.disko
          ];
          buildDiskImage =
            imageName: nixosConfigName: format: diskSize:
            pkgs.callPackage (nixpkgs + "/nixos/lib/make-disk-image.nix") {
              name = imageName;
              inherit format diskSize;
              config = self.nixosConfigurations."${nixosConfigName}".config;
              inherit pkgs;
            };
          mageWrappers = pkgs.runCommand "mage-wrappers" { buildInputs = [ pkgs.makeWrapper ]; } ''
            mkdir -p $out/bin
            makeWrapper ${pkgs.mage}/bin/mage $out/bin/mage --set PATH "${mageEnvPath}" --run "cd ${toString ./.}";
            for target in recreateNode deploy recreateServer deleteAndRedeployServer; do
              makeWrapper ${pkgs.mage}/bin/mage $out/bin/mage-$target --set PATH "${mageEnvPath}" --run "cd ${toString ./.}"; --add-flags "$target";
            done
          '';
        in
        {
          hetznerK3sWorkerRawImage = buildDiskImage "hetzner-k3s-worker-image" "example-node" "raw" "20G";
          hetznerK3sControlRawImage = buildDiskImage "hetzner-k3s-control-image" "example-node" "raw" "20G";
          inherit mageWrappers;
        };

      apps.${system} = {
        mage = {
          type = "app";
          program = "${self.packages.${system}.mageWrappers}/bin/mage";
          meta = with lib; {
            description = "Mage wrapper for project tasks (check, deploy, etc.)";
            # Add other relevant meta attributes if desired
          };
        };
        recreateNode = {
          type = "app";
          program = "${self.packages.${system}.mageWrappers}/bin/mage-recreateNode";
           meta = with lib; {
            description = "App to redeploy a node using nixos-anywhere (destructive)";
            # Add other relevant meta attributes if desired
          };
        };
        deploy = {
          type = "app";
          program = "${self.packages.${system}.mageWrappers}/bin/mage-deploy";
           meta = with lib; {
            description = "App to deploy a NixOS configuration using deploy-rs";
            # Add other relevant meta attributes if desired
          };
        };
        recreateServer = {
          type = "app";
          program = "${self.packages.${system}.mageWrappers}/bin/mage-recreateServer";
           meta = with lib; {
            description = "App to recreate a Hetzner Cloud server (destructive)";
            # Add other relevant meta attributes if desired
          };
        };
        deleteAndRedeployServer = {
          type = "app";
          program = "${self.packages.${system}.mageWrappers}/bin/mage-deleteAndRedeployServer";
           meta = with lib; {
            description = "App to delete, recreate, and deploy to a Hetzner Cloud server (destructive)";
            # Add other relevant meta attributes if desired
          };
        };
        default = self.apps.${system}.mage; # Default app points to the mage wrapper
      };

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          pkgs.just
          pkgs.hcloud
          pkgs.kubectl
          pkgs.kubernetes-helm
          pkgs.fluxcd
          pkgs.tailscale
          deploy-rs.packages.${system}.deploy-rs
          nixos-anywhere.packages.${system}.default
          inputs.nixos-facter-cli.packages.${system}.default # <-- Corrected: Reference 'default' package from the new 'nixos-facter-cli' input
          disko.packages.${system}.disko
          pkgs.mage
          pkgs.go
          pkgs.gotools
          pkgs.gopls
          pkgs.sops
        ];
        shellHook = ''
          echo "---"
          echo "NixOS K3s Cluster DevEnv Activated"
          echo "Ensure required environment variables are set (e.g., K3S_CONTROL_PLANE_ADDR, ADMIN_SSH_PUBLIC_KEY)."
          echo "Ensure ./sops.secrets.yaml is created and encrypted."
          echo "Ensure ./machines.nix exists and is populated (this file is gitignored)."
          echo "Ensure Disko layouts exist (e.g., ./disko-configs/hetzner-disko-layout.nix)."
          echo "Ensure ./dummy-hardware-config.nix exists for local pure flake checks."
          echo "Hardware configs for actual deployments will use /etc/nixos/hardware-configuration.nix (Option A)."
          echo "State version is now applied globally to all machines."
          echo "Hostname will be set from the machine name in machines.nix via common.nix."
          echo "---"
        '';
      };
    };
}
