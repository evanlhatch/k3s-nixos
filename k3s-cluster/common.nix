{
  config,
  lib,
  pkgs,
  specialArgs,
  ...
}:

let
  # Get SSH public key from environment
  sshPublicKey = builtins.getEnv "ADMIN_SSH_PUBLIC_KEY";
in
{
  time.timeZone = "Etc/UTC";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
      "docker"
    ]; # Add docker group if needed
    openssh.authorizedKeys.keys = [ sshPublicKey ];
  };
  
  # Also add the SSH key to the root user for direct SSH access
  users.users.root = {
    openssh.authorizedKeys.keys = [ sshPublicKey ];
  };
  
  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      # Allow root login with public key authentication
      PermitRootLogin = "prohibit-password"; # This already allows public key authentication for root
      PubkeyAuthentication = true;
    };
  };

  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    htop
    vim
    tmux
    jq
  ];

  nixpkgs.config.allowUnfree = true;
}
