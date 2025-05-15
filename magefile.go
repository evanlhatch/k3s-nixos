//go:build mage
// +build mage

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/joho/godotenv"    // For loading .env files
	"github.com/magefile/mage/mg" // mg contains helper functions for Mage
	"github.com/magefile/mage/sh" // sh allows running shell commands
)

func init() {
	// Load .env file if it exists
	err := godotenv.Load()
	if err != nil {
		fmt.Println("INFO: .env file not found or failed to load, using existing environment variables")
	} else {
		fmt.Println("INFO: .env file loaded successfully")

		// Export critical environment variables if they're not already set
		criticalEnvVars := []string{
			"AGE_PRIVATE_KEY",
			"K3S_TOKEN",
			"TAILSCALE_AUTH_KEY",
			"HCLOUD_TOKEN",
			"GITHUB_TOKEN",
		}

		// Read all variables from .env file
		envMap, err := godotenv.Read()
		if err != nil {
			fmt.Println("ERROR: Failed to read .env file:", err)
			return
		}

		// Export critical variables if they're in the .env file and not already set
		for _, envVar := range criticalEnvVars {
			if value, exists := envMap[envVar]; exists && os.Getenv(envVar) == "" {
				os.Setenv(envVar, value)
				fmt.Printf("INFO: Exported %s from .env file\n", envVar)
			}
		}
	}
}

// Default target executed when `mage` is run without arguments.
var Default = CheckFlake

// NodeMap defines the mapping between flake configuration names and their target hosts.
// You should populate this map with your actual nodes.
var nodeMap = map[string]string{
	"cpx21-control-1": "root@5.161.241.28",
	"thinkcenter-1":   "root@100.108.23.65", // Use root user for Tailscale access
	// Add other nodes here, e.g.:
	// "my-hcloud-control01": "root@your_other_node_ip",
}

// CheckFlake runs `nix flake check` to validate the flake.
func CheckFlake() error {
	fmt.Println("INFO: Checking Nix flake...")
	return sh.RunV("nix", "flake", "check", "--show-trace")
}

// UpdateFlake runs `nix flake update` to update all flake inputs.
func UpdateFlake() error {
	fmt.Println("INFO: Updating flake inputs...")
	return sh.RunV("nix", "flake", "update")
}

// ShowFlake runs `nix flake show`.
func ShowFlake() error {
	fmt.Println("INFO: Showing flake outputs...")
	return sh.RunV("nix", "flake", "show")
}

// Deploy deploys a given NixOS configuration to its target host using deploy-rs.
// Usage: mage deploy <flakeConfigName>
// Example: mage deploy cpx21-control-1
func Deploy(flakeConfigName string) error {
	mg.SerialDeps(CheckFlake) // Ensure flake is valid before deploying

	targetHost, ok := nodeMap[flakeConfigName]
	if !ok || targetHost == "" {
		return fmt.Errorf("ERROR: Flake configuration name '%s' not found in nodeMap or target host is empty. Please define it in magefile.go", flakeConfigName)
	}

	fmt.Printf("INFO: Deploying NixOS configuration '%s' to %s via deploy-rs...\n", flakeConfigName, targetHost)
	// Note: deploy-rs uses the hostname defined in the `deploy.nodes.<node>.hostname` attribute in flake.nix for SSH connection.
	// The targetHost from nodeMap is mostly for informational purposes here or if you were to construct ssh commands directly.
	return sh.RunV("deploy-rs", ".#"+flakeConfigName)
}

// Rebuild performs a nixos-rebuild switch on a target node.
// Usage: mage rebuild <flakeConfigName>
// Example: mage rebuild cpx21-control-1
func Rebuild(flakeConfigName string) error {
	targetHost, ok := nodeMap[flakeConfigName]
	if !ok || targetHost == "" {
		return fmt.Errorf("ERROR: Flake configuration name '%s' not found in nodeMap or target host is empty. Please define it in magefile.go", flakeConfigName)
	}

	fmt.Printf("INFO: Rebuilding NixOS configuration '%s' on %s...\n", flakeConfigName, targetHost)
	fmt.Println("IMPORTANT: This assumes your flake source (e.g., from git) is up-to-date on the target machine if it pulls from there.")
	// You might need to adjust the path to your flake on the remote machine.
	// Example assumes it's cloned in /root/k3s-nixos-configs
	cmd := fmt.Sprintf("ssh %s \"cd /root/k3s-nixos-configs && git pull && nixos-rebuild switch --flake .#%s\"", targetHost, flakeConfigName)
	return sh.RunV("bash", "-c", cmd)
}

// RecreateNode redeploys a node using nixos-anywhere and fetches its K3s config.
// This is a more destructive operation and re-images the server.
// Usage: mage recreateNode <flakeConfigName>
// Example: mage recreateNode cpx21-control-1
func RecreateNode(flakeConfigName string) error {
	targetHostVal, ok := nodeMap[flakeConfigName]
	if !ok || targetHostVal == "" {
		return fmt.Errorf("ERROR: Flake configuration name '%s' not found in nodeMap or target host is empty. Please define it in magefile.go", flakeConfigName)
	}

	// Extract user and host for nixos-anywhere, assuming format user@host
	parts := strings.SplitN(targetHostVal, "@", 2)
	if len(parts) != 2 {
		return fmt.Errorf("ERROR: targetHost '%s' for '%s' is not in user@host format", targetHostVal, flakeConfigName)
	}
	targetUser := parts[0]
	targetIP := parts[1]

	// Get SSH key path if provided
	sshKey := os.Getenv("MAGE_SSH_KEY") // e.g., "~/.ssh/id_rsa"

	// Only process the SSH key if it's provided
	if sshKey != "" {
		// Expand ~ to home directory if present
		if strings.HasPrefix(sshKey, "~/") {
			home, err := os.UserHomeDir()
			if err != nil {
				return fmt.Errorf("failed to get home directory: %w", err)
			}
			sshKey = filepath.Join(home, sshKey[2:])
		}

		// Verify SSH key exists
		if _, err := os.Stat(sshKey); os.IsNotExist(err) {
			fmt.Printf("WARNING: SSH key %s does not exist, proceeding without it\n", sshKey)
			sshKey = "" // Clear the SSH key if it doesn't exist
		} else {
			fmt.Printf("INFO: Using SSH key: %s\n", sshKey)
		}
	} else {
		fmt.Println("INFO: No SSH key provided, proceeding without it")
	}

	kubeconfigPath := fmt.Sprintf("%s/.kube/config-%s", os.Getenv("HOME"), flakeConfigName)

	fmt.Printf("INFO: Recreating and deploying '%s' to %s (IP: %s) using nixos-anywhere...\n", flakeConfigName, targetUser, targetIP)

	// Create a temporary directory to store the AGE key
	tempDir, err := os.MkdirTemp("", "nixos-anywhere-age-key")
	if err != nil {
		return fmt.Errorf("failed to create temporary directory for AGE key: %w", err)
	}
	defer os.RemoveAll(tempDir) // Clean up when done

	// Create the directory structure for the AGE key
	ageKeyDir := filepath.Join(tempDir, "etc", "sops", "age")
	if err := os.MkdirAll(ageKeyDir, 0700); err != nil {
		return fmt.Errorf("failed to create AGE key directory: %w", err)
	}

	// Get the AGE key from environment
	ageKey := os.Getenv("AGE_PRIVATE_KEY")
	if ageKey == "" {
		return fmt.Errorf("AGE_PRIVATE_KEY environment variable is not set")
	}

	// Ensure the AGE key has the correct format (should start with AGE-SECRET-KEY-)
	if !strings.HasPrefix(ageKey, "AGE-SECRET-KEY-") {
		return fmt.Errorf("AGE_PRIVATE_KEY has invalid format, should start with AGE-SECRET-KEY-")
	}

	// Write the AGE key to a file
	ageKeyPath := filepath.Join(ageKeyDir, "key.txt")
	if err := os.WriteFile(ageKeyPath, []byte(ageKey), 0600); err != nil {
		return fmt.Errorf("failed to write AGE key: %w", err)
	}

	fmt.Printf("INFO: AGE key written to %s\n", ageKeyPath)

	// Run nixos-anywhere to deploy NixOS to the target machine
	// Hardware configuration will be generated at runtime using facter
	fmt.Printf("INFO: Running nixos-anywhere to deploy NixOS to %s@%s\n", targetUser, targetIP)

	// Build command arguments
	nixosAnywhereArgs := []string{
		"nixos-anywhere",
		"--debug",                    // Enable debug output
		"-f", ".#" + flakeConfigName, // Use -f instead of --flake
	}

	// Add other options
	nixosAnywhereArgs = append(nixosAnywhereArgs,
		"--extra-files", tempDir, // Copy the AGE key to the target machine
		"--substitute-on-destination", // Enable substitutes on the destination
		"--copy-host-keys",            // Copy existing SSH host keys to maintain SSH identity
	)

	// Always use the SSH key if provided
	if sshKey != "" {
		nixosAnywhereArgs = append(nixosAnywhereArgs, "-i", sshKey)
	}

	// Add the target host as the last argument
	nixosAnywhereArgs = append(nixosAnywhereArgs, targetUser+"@"+targetIP)

	fmt.Printf("INFO: Running nixos-anywhere with args: %v\n", nixosAnywhereArgs)

	// Set environment variables for the command
	env := map[string]string{
		"AGE_PRIVATE_KEY": os.Getenv("AGE_PRIVATE_KEY"),
	}

	// Run the command
	err = sh.RunWithV(env, nixosAnywhereArgs[0], nixosAnywhereArgs[1:]...)
	if err != nil {
		return fmt.Errorf("nixos-anywhere deployment failed: %w", err)
	}

	fmt.Printf("INFO: Waiting for %s to reboot and become available...\n", targetIP)
	// Add a sleep or a more sophisticated check for server availability here
	sh.Run("sleep", "30") // Basic wait, adjust as needed

	fmt.Println("INFO: Copying K3s configuration file from the server...")

	// Build SSH command arguments
	sshArgs := []string{
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
	}

	// Add SSH key if provided
	if sshKey != "" {
		sshArgs = append(sshArgs, "-i", sshKey)
	}

	// Add target host and command
	sshArgs = append(sshArgs, targetHostVal, "sudo cat /etc/rancher/k3s/k3s.yaml")

	// Execute SSH command
	k3sConfigContent, err := sh.Output("ssh", sshArgs...)
	if err != nil {
		return fmt.Errorf("failed to copy k3s.yaml: %w", err)
	}

	// Create directory if it doesn't exist
	if err := os.MkdirAll(filepath.Dir(kubeconfigPath), 0755); err != nil {
		return fmt.Errorf("failed to create kubeconfig directory: %w", err)
	}

	if err := os.WriteFile(kubeconfigPath, []byte(k3sConfigContent), 0600); err != nil {
		return fmt.Errorf("failed to write kubeconfig: %w", err)
	}

	fmt.Printf("INFO: K3s config copied to %s\n", kubeconfigPath)
	fmt.Printf("INFO: To use it, run: export KUBECONFIG=%s\n", kubeconfigPath)
	fmt.Printf("INFO: Node '%s' recreated and configured. Tailscale and K3s should be setting up.\n", flakeConfigName)
	return nil
}

// RecreateServer recreates a Hetzner Cloud server with the specified properties.
// Usage: mage recreateServer <serverName> <ipv4Enabled (true/false)>
// Example: mage recreateServer cpx21-control-1 true
func RecreateServer(serverName string, ipv4Enabled string) error {
	mg.SerialDeps(CheckFlake) // Ensure flake is valid before recreating the server

	// Get required environment variables
	hcloudToken := os.Getenv("HCLOUD_TOKEN")
	if hcloudToken == "" {
		return fmt.Errorf("ERROR: HCLOUD_TOKEN environment variable must be set")
	}

	sshKeyName := os.Getenv("HETZNER_SSH_KEY_NAME")
	if sshKeyName == "" {
		return fmt.Errorf("ERROR: HETZNER_SSH_KEY_NAME environment variable must be set")
	}

	privateNetName := os.Getenv("PRIVATE_NETWORK_NAME")
	if privateNetName == "" {
		return fmt.Errorf("ERROR: PRIVATE_NETWORK_NAME environment variable must be set")
	}

	placementGroupName := os.Getenv("PLACEMENT_GROUP_NAME")
	if placementGroupName == "" {
		return fmt.Errorf("ERROR: PLACEMENT_GROUP_NAME environment variable must be set")
	}

	// Get optional environment variables with defaults
	hetznerLocation := os.Getenv("HETZNER_LOCATION")
	if hetznerLocation == "" {
		hetznerLocation = "ash"
		fmt.Printf("INFO: HETZNER_LOCATION not set, defaulting to %s\n", hetznerLocation)
	}

	imageName := os.Getenv("HETZNER_IMAGE_NAME")
	if imageName == "" {
		imageName = "debian-12"
		fmt.Printf("INFO: HETZNER_IMAGE_NAME not set, defaulting to %s\n", imageName)
	}

	serverType := os.Getenv("CONTROL_PLANE_VM_TYPE")
	if serverType == "" {
		serverType = "cpx21"
		fmt.Printf("INFO: CONTROL_PLANE_VM_TYPE not set, defaulting to %s\n", serverType)
	}

	// Construct datacenter name from location
	datacenterName := fmt.Sprintf("%s-dc1", hetznerLocation)

	// Convert ipv4Enabled string to boolean
	var enableIPv4 bool
	if ipv4Enabled == "" {
		// Check environment variable if parameter not provided
		enableIPv4Env := os.Getenv("HETZNER_DEFAULT_ENABLE_IPV4")
		if strings.ToLower(enableIPv4Env) == "true" {
			enableIPv4 = true
		} else {
			enableIPv4 = false
		}
	} else if strings.ToLower(ipv4Enabled) == "true" {
		enableIPv4 = true
	} else if strings.ToLower(ipv4Enabled) == "false" {
		enableIPv4 = false
	} else {
		return fmt.Errorf("ERROR: ipv4Enabled must be either 'true' or 'false'")
	}

	fmt.Printf("INFO: Recreating server %s with IPv4 enabled: %t...\n", serverName, enableIPv4)

	// 1. Delete the existing server
	fmt.Println("INFO: Deleting existing server...")
	err := sh.RunV("hcloud", "server", "delete", serverName, "--force")
	if err != nil && !strings.Contains(err.Error(), "Not Found") {
		return fmt.Errorf("failed to delete server: %w", err)
	}

	// 2. Create a new server with the same properties
	fmt.Println("INFO: Creating new server...")

	var createArgs []string
	createArgs = append(createArgs, "server", "create", serverName)
	createArgs = append(createArgs, "--server-type", serverType)
	createArgs = append(createArgs, "--image", imageName)
	createArgs = append(createArgs, "--datacenter", datacenterName)
	createArgs = append(createArgs, "--ssh-key", sshKeyName)
	createArgs = append(createArgs, "--network", privateNetName)
	createArgs = append(createArgs, "--placement-group", placementGroupName)

	if enableIPv4 {
		createArgs = append(createArgs, "--enable-ipv4")
	}

	// The HCLOUD_TOKEN environment variable will be used automatically

	err = sh.RunV("hcloud", createArgs...)

	if err != nil {
		return fmt.Errorf("failed to create server: %w", err)
	}

	fmt.Printf("INFO: Server %s recreated successfully.\n", serverName)
	return nil
}

// DeleteAndRedeployServer deletes an existing server, recreates it, and then deploys NixOS to it.
// This combines RecreateServer and RecreateNode into a single operation.
// Usage: mage deleteAndRedeployServer <serverName> <flakeConfigName> <ipv4Enabled (optional)>
// Example: mage deleteAndRedeployServer cpx21-control-1 cpx21-control-1 true
func DeleteAndRedeployServer(serverName string, flakeConfigName string, ipv4Enabled string) error {
	fmt.Printf("INFO: Starting complete redeployment of server %s with flake config %s\n", serverName, flakeConfigName)

	// Step 1: Recreate the server
	if err := RecreateServer(serverName, ipv4Enabled); err != nil {
		return fmt.Errorf("failed to recreate server: %w", err)
	}

	// Wait for the server to be fully up
	fmt.Println("INFO: Waiting for server to be fully up...")
	sh.Run("sleep", "30") // Basic wait, adjust as needed

	// Step 2: Deploy NixOS to the server
	if err := RecreateNode(flakeConfigName); err != nil {
		return fmt.Errorf("failed to deploy NixOS to server: %w", err)
	}

	fmt.Printf("INFO: Server %s has been successfully deleted, recreated, and redeployed with NixOS configuration %s\n",
		serverName, flakeConfigName)
	return nil
}

// DecryptSecrets decrypts the sops.secrets.yaml file and prints its content.
// Requires the AGE_PRIVATE_KEY environment variable to be set.
func DecryptSecrets() error {
	fmt.Println("INFO: Decrypting sops.secrets.yaml...")

	// The init() function should have loaded AGE_PRIVATE_KEY from .env
	ageKey := os.Getenv("AGE_PRIVATE_KEY")
	if ageKey == "" {
		// Check again, in case init() didn't run or .env was missing the key
		fmt.Println("ERROR: AGE_PRIVATE_KEY environment variable is not set.")
		fmt.Println("Please ensure it is defined in your .env file and you have run 'direnv allow' or manually exported it.")
		return fmt.Errorf("AGE_PRIVATE_KEY not set")
	}

	// sops expects the key in SOPS_AGE_KEY, so we set it for the sops command.
	env := map[string]string{
		"SOPS_AGE_KEY": ageKey,
	}

	// Run the sops decrypt command
	err := sh.RunWithV(env, "sops", "--decrypt", "sops.secrets.yaml")
	if err != nil {
		return fmt.Errorf("failed to decrypt sops.secrets.yaml: %w", err)
	}

	fmt.Println("INFO: Decryption complete.")
	fmt.Println("WARNING: The decrypted secrets were printed to your console. Be mindful of your environment.")

	return nil
}

// Alias for CheckFlake
var Check = CheckFlake

// Helper function to get a filepath, used by RecreateNode
// Not directly used by user, but good to have if needed for other funcs
func getDir(path string) string {
	return filepath.Dir(path)
}

// DeployControlNode deploys a self-hosted control node to the Debian machine at 100.108.23.65
// This is a convenience function that calls RecreateNode with the thinkcenter-1 configuration
// Usage: mage deployControlNode
func DeployControlNode() error {
	fmt.Println("INFO: Deploying self-hosted control node to Debian machine at 100.108.23.65...")

	// Check if AGE_PRIVATE_KEY is set
	if os.Getenv("AGE_PRIVATE_KEY") == "" {
		fmt.Println("WARNING: AGE_PRIVATE_KEY environment variable is not set. Make sure it's in your .env file.")
	}

	// Call RecreateNode with the thinkcenter-1 configuration
	return RecreateNode("thinkcenter-1")
}
