//go:build mage
// +build mage

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/joho/godotenv"    // For loading .env files
	"github.com/magefile/mage/mg" // mg contains helper functions for Mage
	"github.com/magefile/mage/sh" // sh allows running shell commands
)

// -----------------------------------------------------------------------------
// Configuration Variables (Edit these if needed)
// -----------------------------------------------------------------------------

// criticalEnvVars lists environment variables that should be explicitly checked and exported from .env.
// This list is for informational/safety purposes in the init() function.
var criticalEnvVars = []string{
	"AGE_PRIVATE_KEY",
	"K3S_TOKEN",
	"TAILSCALE_AUTH_KEY",
	"HCLOUD_TOKEN",
	"GITHUB_TOKEN",
}

// defaultSSHKey is the path to the SSH private key used for connecting to nodes.
// This is used by the RecreateNode function if the MAGE_SSH_KEY env var is not set.
// It's recommended to set MAGE_SSH_KEY in your .env file.
var defaultSSHKey = "~/.ssh/id_rsa"

// -----------------------------------------------------------------------------
// Initialization
// -----------------------------------------------------------------------------

func init() {
	// Load .env file if it exists. This makes environment variables available.
	err := godotenv.Load()
	if err != nil {
		fmt.Println("INFO: .env file not found or failed to load, using existing environment variables")
	} else {
		fmt.Println("INFO: .env file loaded successfully")
		// Note: godotenv.Load() automatically sets environment variables.
		// The criticalEnvVars list and loop below are primarily for logging
		// which variables were successfully exported from the .env file.

		// Read all variables from .env file to check which critical ones were set
		envMap, readErr := godotenv.Read()
		if readErr != nil {
			fmt.Println("ERROR: Failed to read .env file:", readErr)
			// Continue execution as existing env vars might be sufficient
		} else {
			for _, envVar := range criticalEnvVars {
				if _, exists := envMap[envVar]; exists {
					// Check if it was actually loaded (os.Getenv) as init() runs before main
					// and env vars from .env are set by godotenv.Load().
					if os.Getenv(envVar) != "" {
						fmt.Printf("INFO: Critical variable %s found in .env\n", envVar)
					} else {
						fmt.Printf("WARNING: Critical variable %s found in .env but not set in environment?\n", envVar)
					}
				} else {
					fmt.Printf("WARNING: Critical variable %s not found in .env\n", envVar)
				}
			}
		}
	}
}

// -----------------------------------------------------------------------------
// Default Target
// -----------------------------------------------------------------------------

// Default target executed when `mage` is run without arguments.
var Default = CheckFlake

// -----------------------------------------------------------------------------
// Core Mage Targets
// -----------------------------------------------------------------------------

// CheckFlake runs `nix flake check` to validate the flake.
func CheckFlake() error {
	fmt.Println("INFO: Checking Nix flake...")
	// --show-trace is useful for debugging evaluation errors
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
// This is typically used for *updating* an existing installation.
// Usage: mage deploy <flakeConfigName>
// Example: mage deploy cpx21-control-1
func Deploy(flakeConfigName string) error {
	mg.SerialDeps(CheckFlake) // Ensure flake is valid before deploying

	fmt.Printf("INFO: Deploying NixOS configuration '%s' via deploy-rs...\n", flakeConfigName)
	// deploy-rs reads the target host and user from the flake's deploy.nodes.<name> attribute.
	return sh.RunV("deploy-rs", ".#"+flakeConfigName)
}

// Rebuild performs a nixos-rebuild switch on a target node.
// This requires the flake source to be present and up-to-date on the target machine.
// Usage: mage rebuild <flakeConfigName>
// Example: mage rebuild cpx21-control-1
func Rebuild(flakeConfigName string) error {
	// Get target host and user from the flake configuration
	targetHostVal, err := getFlakeDeployTarget(flakeConfigName)
	if err != nil {
		return fmt.Errorf("failed to get deploy target from flake for '%s': %w", flakeConfigName, err)
	}

	fmt.Printf("INFO: Rebuilding NixOS configuration '%s' on %s...\n", flakeConfigName, targetHostVal)
	fmt.Println("IMPORTANT: This assumes your flake source (e.g., from git) is up-to-date on the target machine if it pulls from there.")
	// You might need to adjust the path to your flake on the remote machine.
	// Example assumes it's cloned in /root/k3s-nixos-configs
	cmd := fmt.Sprintf("ssh %s 'cd /root/k3s-nixos && git pull && nixos-rebuild switch --flake .#%s'", targetHostVal, flakeConfigName)
	return sh.RunV("bash", "-c", cmd)
}

// RecreateNode redeploys a node using nixos-anywhere.
// This is a more destructive operation and re-images the server.
// It also generates hardware config using nixos-facter and deploys secrets.
// Usage: mage recreateNode <flakeConfigName>
// Example: mage recreateNode cpx21-control-1
func RecreateNode(flakeConfigName string) error {
	// Get target host and user from the flake configuration
	targetHostVal, err := getFlakeDeployTarget(flakeConfigName)
	if err != nil {
		return fmt.Errorf("failed to get deploy target from flake for '%s': %w", flakeConfigName, err)
	}

	// Extract user and host for nixos-anywhere, assuming format user@host
	parts := strings.SplitN(targetHostVal, "@", 2)
	if len(parts) != 2 {
		return fmt.Errorf("ERROR: deploy target '%s' for '%s' is not in user@host format", targetHostVal, flakeConfigName)
	}
	targetUser := parts[0]
	targetIP := parts[1] // This might be an IP or hostname resolvable by SSH

	// Get SSH key path, prioritizing MAGE_SSH_KEY env var
	sshKey := os.Getenv("MAGE_SSH_KEY")
	if sshKey == "" {
		sshKey = defaultSSHKey // Fallback to default if env var is not set
		fmt.Printf("INFO: MAGE_SSH_KEY environment variable not set, using default: %s\n", sshKey)
	}

	// Expand ~ to home directory if present
	if strings.HasPrefix(sshKey, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return fmt.Errorf("failed to get home directory: %w", err)
		}
		sshKey = filepath.Join(home, sshKey[2:])
	}

	// Verify SSH key exists (optional but good practice)
	if _, err := os.Stat(sshKey); os.IsNotExist(err) {
		return fmt.Errorf("ERROR: SSH key not found at %s", sshKey)
	}
	fmt.Printf("INFO: Using SSH key: %s\n", sshKey)

	// Create a temporary directory to store the AGE key locally before copying
	tempDir, err := os.MkdirTemp("", "nixos-anywhere-age-key")
	if err != nil {
		return fmt.Errorf("failed to create temporary directory for AGE key: %w", err)
	}
	defer os.RemoveAll(tempDir) // Clean up when done

	// Create the directory structure for the AGE key within the temp dir
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

	// Write the AGE key to a file in the temporary directory
	ageKeyPath := filepath.Join(ageKeyDir, "key.txt")
	if err := os.WriteFile(ageKeyPath, []byte(ageKey), 0600); err != nil {
		return fmt.Errorf("failed to write AGE key: %w", err)
	}

	fmt.Printf("INFO: AGE key written to temporary path %s for deployment\n", ageKeyPath)

	// Run nixos-anywhere to deploy NixOS to the target machine.
	// It will use disko based on the flake config.
	// It will generate hardware config using nixos-facter and save the report to /tmp/facter.json on target.
	// It will copy the AGE key from the local tempDir to the target's installer environment.
	fmt.Printf("INFO: Running nixos-anywhere to deploy NixOS to %s@%s...\n", targetUser, targetIP)

	// Build command arguments
	nixosAnywhereArgs := []string{
		"nixos-anywhere",
		"--debug",                    // Enable debug output
		"-f", ".#" + flakeConfigName, // Use -f instead of --flake
		"--generate-hardware-config", "nixos-facter", "/tmp/facter.json", // Generate facter report and save to /tmp/facter.json on target
		"--extra-files", tempDir, // Copy the local tempDir (containing AGE key) to the target
		"--substitute-on-destination", // Enable substitutes on the destination
		"--copy-host-keys",            // Copy existing SSH host keys to maintain SSH identity
		"-i", sshKey,                  // Specify the SSH identity file
		targetUser + "@" + targetIP, // The target host
	}

	fmt.Printf("INFO: Running nixos-anywhere with args: %v\n", nixosAnywhereArgs)

	// nixos-anywhere handles SSH connection and remote command execution.
	// We don't need to manually set SSH environment variables here.
	err = sh.RunV(nixosAnywhereArgs[0], nixosAnywhereArgs[1:]...)
	if err != nil {
		return fmt.Errorf("nixos-anywhere deployment failed: %w", err)
	}

	fmt.Printf("INFO: Waiting for %s to reboot and become available...\n", targetIP)
	// Add a sleep or a more sophisticated check for server availability here
	sh.Run("sleep", "30") // Basic wait, adjust as needed

	fmt.Println("INFO: Attempting to copy K3s configuration file from the server...")

	// Build SSH command arguments to fetch the k3s.yaml
	// We need to connect as the root user on the *newly installed* system.
	// The targetHostVal from the flake config should be the correct address.
	sshFetchArgs := []string{
		"ssh",
		"-i", sshKey, // Use the same SSH key
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		targetHostVal,                        // Connect to the target host from flake config
		"sudo cat /etc/rancher/k3s/k3s.yaml", // Command to run on target
	}

	// Execute SSH command
	k3sConfigContent, err := sh.Output(sshFetchArgs[0], sshFetchArgs[1:]...)
	if err != nil {
		fmt.Printf("WARNING: Failed to copy k3s.yaml from %s. This might be expected if K3s isn't fully up yet or if this is not a control plane node: %v\n", targetHostVal, err)
		// Don't return an error here, as the node might still be setting up K3s.
		// The user can try fetching the kubeconfig manually later.
	} else {
		// Create directory if it doesn't exist
		if err := os.MkdirAll(filepath.Dir(kubeconfigPath), 0755); err != nil {
			return fmt.Errorf("failed to create kubeconfig directory: %w", err)
		}

		if err := os.WriteFile(kubeconfigPath, []byte(k3sConfigContent), 0600); err != nil {
			return fmt.Errorf("failed to write kubeconfig: %w", err)
		}

		fmt.Printf("INFO: K3s config copied to %s\n", kubeconfigPath)
		fmt.Printf("INFO: To use it, run: export KUBECONFIG=%s\n", kubeconfigPath)
	}

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
		imageName = "debian-12" // Default to a common installer image
		fmt.Printf("INFO: HETZNER_IMAGE_NAME not set, defaulting to %s\n", imageName)
	}

	serverType := os.Getenv("CONTROL_PLANE_VM_TYPE") // Assuming this is for control planes
	// You might want to add logic to select server type based on flakeConfigName if needed
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
	// Use --ignore-not-found to avoid error if server doesn't exist
	err := sh.RunV("hcloud", "server", "delete", serverName, "--force", "--ignore-not-found")
	if err != nil {
		return fmt.Errorf("failed to delete server: %w", err)
	}
	fmt.Printf("INFO: Server %s deleted (or did not exist).\n", serverName)

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

	// The HCLOUD_TOKEN environment variable will be used automatically by the hcloud CLI

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

	// Step 1: Recreate the server (deletes and creates)
	if err := RecreateServer(serverName, ipv4Enabled); err != nil {
		return fmt.Errorf("failed to recreate server: %w", err)
	}

	// Wait for the server to boot up and become available for SSH
	fmt.Println("INFO: Waiting for server to be fully up and SSHable...")
	// A simple sleep might not be enough. Consider a loop with ssh checks.
	sh.Run("sleep", "60") // Increased wait time, adjust as needed

	// Step 2: Deploy NixOS to the server using nixos-anywhere
	// Note: RecreateNode will get the SSH details from the flake config for flakeConfigName
	if err := RecreateNode(flakeConfigName); err != nil {
		return fmt.Errorf("failed to deploy NixOS to server: %w", err)
	}

	fmt.Printf("INFO: Server %s has been successfully deleted, recreated, and redeployed with NixOS configuration %s\n",
		serverName, flakeConfigName)
	return nil
}

// DecryptSecrets decrypts the sops.secrets.yaml file and prints its content.
// Requires the AGE_PRIVATE_KEY environment variable to be set.
// Usage: mage DecryptSecrets
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

// -----------------------------------------------------------------------------
// Helper Functions
// -----------------------------------------------------------------------------

// getFlakeDeployTarget evaluates the flake to get the deploy.nodes.<name>.sshHostname
// and sshUser attributes and returns them in user@host format.
func getFlakeDeployTarget(flakeConfigName string) (string, error) {
	// Evaluate the deploy.nodes.<name> attribute from the flake
	// We need --impure because the flake uses getEnv
	// We need --json to easily parse the result
	// We need --show-trace for debugging evaluation errors
	flakeAttrPath := fmt.Sprintf(".#deploy.nodes.%s", flakeConfigName)
	fmt.Printf("INFO: Evaluating flake attribute '%s' to get deploy target...\n", flakeAttrPath)

	// Use sh.Output to capture the JSON output
	jsonOutput, err := sh.Output("nix", "eval", "--json", "--impure", "--show-trace", flakeAttrPath)
	if err != nil {
		return "", fmt.Errorf("failed to evaluate flake attribute '%s': %w", flakeAttrPath, err)
	}

	// Parse the JSON output
	var deployConfig struct {
		SSHHostname string `json:"sshHostname"`
		SSHUser     string `json:"sshUser"`
	}
	err = json.Unmarshal([]byte(jsonOutput), &deployConfig)
	if err != nil {
		return "", fmt.Errorf("failed to parse JSON output from nix eval: %w", err)
	}

	if deployConfig.SSHHostname == "" || deployConfig.SSHUser == "" {
		return "", fmt.Errorf("deploy target (sshHostname or sshUser) is empty for '%s'. Ensure it's defined in machines.nix and corresponding environment variables are set in .env", flakeConfigName)
	}

	return fmt.Sprintf("%s@%s", deployConfig.SSHUser, deployConfig.SSHHostname), nil
}

// getDir is a helper to get the directory of a path. Not directly used by user targets.
func getDir(path string) string {
	return filepath.Dir(path)
}

// DeployControlNode is a convenience function to deploy the thinkcenter-1 node.
// It's an alias for `mage recreateNode thinkcenter-1`.
// Usage: mage DeployControlNode
func DeployControlNode() error {
	fmt.Println("INFO: Deploying self-hosted control node (thinkcenter-1)...")
	// Call RecreateNode with the specific configuration name
	return RecreateNode("thinkcenter-1")
}
