# K3s NixOS Configs

This repository contains NixOS configurations for a K3s Kubernetes cluster.

At its core, this project leverages the power of NixOS to declaratively define your entire infrastructure. By combining NixOS's reproducible system management with a modular flake structure, you gain the ability to onboard virtually any machine – from cloud servers to old laptops – convert them into reproducible NixOS systems, and automatically integrate them into a robust K3s cluster using Tailscale for secure networking and CNI. This approach drastically simplifies cluster management, ensuring consistency across diverse hardware and providing a seamless, secure network fabric via Tailscale that "just works," regardless of the underlying physical network.

## Prerequisites

* [Nix](https://nixos.org/download.html) with flakes enabled
* [mage](https://magefile.org/) - Available in `nixpkgs`
* Required environment variables set in a `.env` file (copy `.env.example`)
* `./machines.nix` file created with your node definitions (this file should be gitignored)
* `./sops.secrets.yaml` file created and encrypted with your secrets

## Setup

1.  Clone the repository.
2.  Copy the `.env.example` file to `.env` and fill in the required values.
3.  Create your `./machines.nix` file, defining your nodes and their properties (refer to the structure in `flake.nix` or the `machines.nix.example`). Add `./machines.nix` to your `.gitignore`.
4.  Create your `./sops.secrets.yaml` file with your encrypted secrets. Ensure your AGE key is configured to decrypt it (see SOPS documentation for setup).

## Available Commands

Run `mage -l` to see all available commands:

**Targets:**

* `checkFlake*` - Runs `nix flake check` to validate the flake. (*default target*)
* `deleteAndRedeployServer` - Deletes an existing server, recreates it, and then deploys NixOS to it.
* `deploy` - Deploys a given NixOS configuration to its target host using `deploy-rs` (for updates).
* `rebuild` - Performs a `nixos-rebuild switch` on a target node (requires flake source on target).
* `recreateNode` - Redeploys a node using `nixos-anywhere` (for initial install or re-imaging).
* `recreateServer` - Recreates a Hetzner Cloud server with the specified properties (destructive).
* `showFlake` - Runs `nix flake show`.
* `updateFlake` - Runs `nix flake update` to update all flake inputs.

### Common Usage (via Mage)

This repository uses `mage` to orchestrate common deployment tasks. The primary commands you will use are `deploy` and `recreateNode`.

* **`mage deploy <flakeConfigName>`**: Use this command for **updating** an existing NixOS installation on a node. It uses `deploy-rs` behind the scenes.
    * Example: `mage deploy thinkcenter-1`
    * Example: `mage deploy cpx21-control-1`

* **`mage recreateNode <flakeConfigName>`**: Use this command for the **initial installation** of NixOS on a new machine or to **re-image** an existing one. It uses `nixos-anywhere` behind the scenes. This is a destructive operation.
    * Example: `mage recreateNode thinkcenter-1`
    * Example: `mage recreateNode cpx21-control-1`

* **`mage recreateServer <serverName> <ipv4Enabled>`**: Recreates a Hetzner Cloud server (destructive).
    * Example: `mage recreateServer cpx21-control-1 true`

* **`mage deleteAndRedeployServer <serverName> <flakeConfigName> <ipv4Enabled>`**: Combines `recreateServer` and `recreateNode` for a full tear-down and redeploy (destructive).
    * Example: `mage deleteAndRedeployServer cpx21-control-1 cpx21-control-1 true`

### Advanced Usage: Raw Commands

For more direct control or debugging, you can use `deploy-rs` and `nixos-anywhere` directly.

* **Using `deploy-rs` directly (for updates):**
    `deploy-rs` reads deployment information from the `deploy.nodes.<name>` attribute in your flake.
    ```bash
    nix run deploy-rs -- .#your-node-name
    ```
    Replace `your-node-name` with the flake configuration name (e.g., `thinkcenter-1`). This command will execute the deployment based on the `sshHostname`, `sshUser`, etc., defined in your flake's `deploy.nodes.your-node-name` section (which is populated from your `machines.nix`).

* **Using `nixos-anywhere` directly (for initial installs/re-imaging):**
    `nixos-anywhere` requires you to specify the target host and flake details directly on the command line. You often need to pass extra files, such as your AGE private key for SOPS decryption, and configure hardware detection.
    ```bash
    # Example for thinkcenter-1 using Tailscale IP and sops secrets
    cd /home/evan/2_Dev/2.1_Homelab/k3s-nixos && \
    mkdir -p /tmp/nixos-extra/etc/sops/age && \
    echo "$AGE_PRIVATE_KEY" > /tmp/nixos-extra/etc/sops/age/key.txt && \
    chmod 600 /tmp/nixos-extra/etc/sops/age/key.txt && \
    nixos-anywhere -f .#thinkcenter-1 \
      --generate-hardware-config nixos-facter /etc/nixos/hardware-configuration.nix \
      --extra-files /tmp/nixos-extra \
      --copy-host-keys \
      --debug \
      root@100.108.75.64 # Replace with the actual SSH target (user@host)
    ```
    This complex command manually sets up the AGE key for the installer, tells `nixos-anywhere` to use `nixos-facter` to generate the hardware config, copies existing SSH host keys, enables debug output, and specifies the flake target (`.#thinkcenter-1`) and the SSH destination (`root@100.108.75.64`). The `mage recreateNode` command wraps this complexity for easier use.

## Optional Development Environment

This project also includes a [devenv](https://devenv.sh/) configuration for those who prefer a more isolated development environment.

### Setup with devenv

1.  Install [direnv](https://direnv.net/docs/installation.html) and [devenv](https://devenv.sh/getting-started/).
2.  Run `direnv allow` to automatically load the devenv environment when entering the directory.

## Deploying to the "thinkcenter-1" Machine

To perform an initial installation or re-image the "thinkcenter-1" machine (your local node) via Tailscale SSH using the simplified `mage` command:

```bash
mage recreateNode thinkcenter-1
