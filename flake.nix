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
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-facter-modules = {
      url = "github:nix-community/nixos-facter-modules"; # Or your preferred facter modules source
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
      nixos-facter-modules,
      ... # Allow other inputs if present
    }@inputs:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib; # Shortcut for lib

      getEnv =
        name: defaultValue:
        let
          value = builtins.getEnv name;
        in
        if value == "" then defaultValue else value;

      # stateVersionModule is now defined here and used directly in mkNixosSystem
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
          sops.age.keyFile = "/etc/sops/age/key.txt"; # Deployed securely by nixos-anywhere via --extra-files
          sops.age.generateKey = false;
          sops.validateSopsFiles = false; # Set to true for production checks if desired

          # Common SOPS secrets (keys must exist in ./sops.secrets.yaml)
          sops.secrets.infisical_client_id = { };
          sops.secrets.infisical_client_secret = { };
          sops.secrets.infisical_address = { };
          sops.secrets.K3S_CLUSTER_JOIN_TOKEN = { }; # For joining nodes
          sops.secrets.TAILSCALE_PROVISION_KEY = { }; # For provisioning Tailscale

          sops.defaultSopsFile = "/etc/nixos/secrets.sops.yaml"; # Path where encrypted SOPS file is deployed

          system.activationScripts.deploySopsFile =
            lib.mkIf (config.sops.defaultSopsFile != null && builtins.pathExists ./sops.secrets.yaml)
              {
                text = ''
                  echo "Copying encrypted sops file to target system..."
                  mkdir -p "$(dirname "${config.sops.defaultSopsFile}")"
                  cp ${./sops.secrets.yaml} "${config.sops.defaultSopsFile}" # ./sops.secrets.yaml is your encrypted file at flake root
                  chmod 0400 "${config.sops.defaultSopsFile}"
                  echo "Encrypted sops file deployed to ${config.sops.defaultSopsFile}"
                '';
                deps = [ "users" ];
              };
          systemd.tmpfiles.rules = [ "d /etc/sops/age 0700 root root -" ];
        };

      commonNodeArguments = {
        k3sControlPlaneAddr = getEnv "K3S_CONTROL_PLANE_ADDR" "https://REPLACE_ME_K3S_API_ENDPOINT:6443";
        adminUsername = getEnv "ADMIN_USERNAME" "nixos_admin";
        adminSshPublicKey = getEnv "ADMIN_SSH_PUBLIC_KEY" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB_REPLACE_ME_YOUR_PUBLIC_KEY";
        nixosStateVersion = getEnv "NIXOS_STATE_VERSION" "25.05"; # Global state version
        hetznerPublicInterface = getEnv "HETZNER_PUBLIC_INTERFACE" "eth0";
        hetznerPrivateInterface = getEnv "HETZNER_PRIVATE_INTERFACE" "ens10";
      };

      # Mappings for deriving paths and settings from location and nodeType
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

      mkNixosSystem =
        {
          # Parameters are now mostly derived based on location and nodeType from allMachinesData
          derivedRolePath,
          derivedLocationProfilePath,
          derivedDiskoConfigPath,
          extraModules ? [ ], # For machine-specific modules (e.g., unique SOPS secrets)
          specialArgsResolved, # The fully merged specialArgs for this system
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
            commonSopsModule
            ./k3s-cluster/profiles/base-server.nix # Contains LVM initrd fix and imports common.nix
            derivedRolePath
            derivedLocationProfilePath
            inputs.disko.nixosModules.disko
            derivedDiskoConfigPath # Selected based on location

            # << MODIFIED >> Automatically include the state version module using the resolved state version
            (stateVersionModule specialArgsResolved.nixosStateVersion)

            /etc/nixos/hardware-configuration.nix # Option A: Always use installer-generated hardware config
          ] ++ extraModules; # For any other specific modules from machines.nix
          specialArgs = specialArgsResolved;
        };

      privateMachinesPath = ./machines.nix; # This file will be in your .gitignore
      allMachinesData =
        if builtins.pathExists privateMachinesPath then
          (import privateMachinesPath {
            inherit
              lib
              pkgs
              getEnv
              stateVersionModule
              ; # Pass helpers if machines.nix needs them for complex extraModules
            # commonNixosStateVersion is no longer needed here as stateVersionModule is applied globally
          })
        else
          {
            # Fallback if machines.nix is not found
            "example-node" = {
              location = "local";
              nodeType = "control-init";
              # extraModules = []; # No need for stateVersionModule here anymore
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

          # Layering specialArgs:
          # 1. Flake commonNodeArguments (global defaults, can use getEnv)
          # 2. Derived from nodeType & location (isFirstControlPlane, location itself)
          # 3. Hostname (defaults to the machine's attribute name)
          # 4. Instance specific overrides from machines.nix (machineData.specialArgsOverride)
          resolvedSpecialArgs =
            commonNodeArguments
            // {
              location = machineData.location;
              isFirstControlPlane = isFirstCp;
            } # Derived values
            // {
              hostname = name;
            } # Hostname defaults to the attribute name (e.g., "cpx21-control-1")
            // (machineData.specialArgsOverride or { });
        in
        mkNixosSystem {
          derivedRolePath = finalRolePath;
          derivedLocationProfilePath = finalLocationProfilePath;
          derivedDiskoConfigPath = finalDiskoConfigPath;
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

      packages.${system} = # ... (remains the same as previous response)
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
            inputs.nixos-facter-modules.packages.${system}.default # facter CLI
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
          hetznerK3sWorkerRawImage = buildDiskImage "hetzner-k3s-worker-image" "example-node" "raw" "20G"; # Update to a real node name
          hetznerK3sControlRawImage = buildDiskImage "hetzner-k3s-control-image" "example-node" "raw" "20G"; # Update to a real node name
          inherit mageWrappers;
        };

      apps.${system} = {
        # ... (remains the same as previous response) ...
      };
      devShells.${system}.default = {
        # ... (remains the same as previous response, ensure shellHook is updated) ...
        shellHook = ''
          echo "---"
          echo "NixOS K3s Cluster DevEnv Activated"
          echo "Ensure required environment variables are set (e.g., K3S_CONTROL_PLANE_ADDR, ADMIN_SSH_PUBLIC_KEY)."
          echo "Ensure ./sops.secrets.yaml is created and encrypted."
          echo "Ensure ./machines.nix exists and is populated (this file is gitignored)."
          echo "Ensure Disko layouts exist (e.g., ./disko-configs/hetzner-disko-layout.nix)."
          echo "Hardware configs will be generated by nixos-anywhere in the installer (Option A)."
          echo "State version is now applied globally to all machines."
          echo "Hostname will be set from the machine name in machines.nix."
          echo "---"
        '';
      };
    };
}
