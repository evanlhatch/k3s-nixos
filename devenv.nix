{ pkgs, ... }:

{
  # Enable devenv shell features
  packages = with pkgs; [
    # Core tools
    go
    mage

    # Deployment tools
    deploy-rs
    nixos-anywhere
    disko

    # Cloud tools
    hcloud
    kubectl
    kubernetes-helm
    fluxcd
    tailscale
  ];

  # Set up environment variables
  env = {
    GOPATH = "$HOME/go";
    PATH = "$GOPATH/bin:$PATH";
    GO111MODULE = "on";
  };

  # Load environment variables from .env file
  dotenv.enable = true;
  dotenv.filename = ".env";

  # Pre-install Go dependencies
  enterShell = ''
    echo "K3s NixOS Configs Development Environment"
    echo "Installing Go dependencies..."
    go install github.com/joho/godotenv@latest
    go install github.com/magefile/mage@latest
    echo "Available mage commands:"
    mage -l 2>/dev/null || echo "mage not installed or no targets defined."
  '';

  # Scripts that can be run with `devenv up <name>`
  scripts = {
    deploy.exec = "mage deploy $@";
    recreate-node.exec = "mage recreateNode $@";
    recreate-server.exec = "mage recreateServer $@";
    delete-and-redeploy-server.exec = "mage deleteAndRedeployServer $@";
  };

  # Enter the development environment with the project directory as the working directory
  enterShell = ''
    echo "K3s NixOS Configs Development Environment"
    echo "Available mage commands:"
    mage -l 2>/dev/null || echo "mage not installed or no targets defined."
  '';

  # Ensure the project directory is the working directory
  processes = {
    # You can define long-running processes here if needed
  };
}
