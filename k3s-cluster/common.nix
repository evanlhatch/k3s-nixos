# ./k3s-cluster/common.nix
# Contains settings common to ALL NixOS systems built from this flake.
{
  config,
  lib,
  pkgs,
  ...
}: # specialArgs are available via config.specialArgs

{

  # \----- Hostname Configuration -----

  # Set from specialArgs.hostname, which defaults to the machine's name from machines.nix (via flake.nix)
  networking.hostName = lib.mkDefault config.specialArgs.hostname;

  # \----- Localization -----

  time.timeZone = "Etc/UTC"; # Consider setting your actual timezone, e.g., "America/Denver"
  i18n.defaultLocale = "en\_US.UTF-8";
  console.keyMap = "us";

  # \----- Admin User Account -----

  # Create the admin user specified in commonNodeArguments (via specialArgs)
  users.users.${config.specialArgs.adminUsername} = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
      "docker"
    ];
    openssh.authorizedKeys.keys = [ config.specialArgs.adminSshPublicKey ];
    shell = pkgs.fish;
  };

  # Add the same admin SSH key to the root user for initial provisioning or recovery

  users.users.root.openssh.authorizedKeys.keys = [ config.specialArgs.adminSshPublicKey ];

  # Sudo privileges for the wheel group (adminUser is typically in 'wheel')

  security.sudo.wheelNeedsPassword = false; # Set to true to require password for sudo

  # \----- Global Nix Configuration -----

  nixpkgs.config.allowUnfree = true; # Allow unfree packages if needed globally

  nix = {
    package = pkgs.nixFlakes; # Ensures the Flakes-aware Nix package is used
    settings = {
      auto-optimise-store = true;
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      # Add the admin user to trusted-users to perform Nix operations without sudo (e.g., nix build)
      trusted-users = [
        "root"
        "@wheel"
        config.specialArgs.adminUsername
      ];
    };
    # Automatic garbage collection
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  # \----- Time Synchronization -----

  services.timesyncd.enable = true; # Essential for most systems

  # \----- Basic System Environment -----

  # Minimal set of universally useful tools; more can go in base-server.nix

  environment.systemPackages = with pkgs; [
    gitMinimal
    micro
    curl
    wget
  ];

  environment.variables.EDITOR = "micro";
}
