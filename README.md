# K3s NixOS Configs

This repository contains NixOS configurations for a K3s Kubernetes cluster.

## Prerequisites

- [Nix](https://nixos.org/download.html) with flakes enabled
- [mage](https://magefile.org/) - Available in nixpkgs

## Setup

1. Clone the repository
2. Copy the `.env.example` file to `.env` and fill in the required values

## Available Commands

Run `mage -l` to see all available commands:

```
Targets:
  checkFlake*                runs `nix flake check` to validate the flake.
  deleteAndRedeployServer    deletes an existing server, recreates it, and then deploys NixOS to it.
  deploy                     deploys a given NixOS configuration to its target host using deploy-rs.
  rebuild                    performs a nixos-rebuild switch on a target node.
  recreateNode               redeploys a node using nixos-anywhere and fetches its K3s config.
  recreateServer             recreates a Hetzner Cloud server with the specified properties.
  showFlake                  runs `nix flake show`.
  updateFlake                runs `nix flake update` to update all flake inputs.

* default target
```

### Common Usage

- `mage deploy <flakeConfigName>`: Deploy a NixOS configuration using deploy-rs
- `mage recreateNode <flakeConfigName>`: Deploy a NixOS configuration using nixos-anywhere
- `mage recreateServer <serverName> <ipv4Enabled>`: Recreate a Hetzner Cloud server
- `mage deleteAndRedeployServer <serverName> <flakeConfigName> <ipv4Enabled>`: Delete and redeploy a server

## Optional Development Environment

This project also includes a [devenv](https://devenv.sh/) configuration for those who prefer a more isolated development environment.

### Setup with devenv

1. Install [direnv](https://direnv.net/docs/installation.html) and [devenv](https://devenv.sh/getting-started/)
2. Run `direnv allow` to automatically load the devenv environment when entering the directory

## Deploying to the "debian" Machine

To deploy to the "debian" machine (thinkcenter-1) via Tailscale SSH:

```bash
mage recreateNode thinkcenter-1
```

This will deploy the NixOS configuration to the existing machine via Tailscale SSH. Make sure the AGE_PRIVATE_KEY environment variable is set in your .env file for secrets decryption.

### Note on Hardware Configuration

The hardware-configuration.nix file for the machine will be created by nixos-anywhere during the installation process. You don't need to create this file manually.

If you're getting an error about missing hardware-configuration.nix when running `nix flake check`, this is expected before the first deployment. The file will be created during the deployment process.
