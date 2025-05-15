# ./k3s-cluster/profiles/base-server.nix
{
  config,
  lib,
  pkgs,
  inputs ? { }, # Available if passed by flake's mkNixosSystem specialArgs
  ...
}:

{
  imports = [
    ../common.nix
    # Imports global settings like hostname, admin user, base Nix config
    # Adjust path if common.nix is located elsewhere relative to this file.
    # Modules specific to your k3s cluster servers:
    ../modules/tailscale.nix
    ../modules/infisical-agent.nix # Conditionally enabled via specialArgs from flake.nix
    ../modules/netdata.nix
    # Disko layout and hardware-configuration.nix are handled by flake.nix's mkNixosSystem
  ];

  # ----- LVM Support for Boot -----
  # Crucial if your Disko configuration uses LVM for the root filesystem
  boot.initrd.lvm.enable = true;

  # ----- Server-Specific System Configuration -----
  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  # Firewall is enabled here; specific rules can be added by roles/locations or directly here.
  networking.firewall.enable = true;

  # Server-Specific Packages (common.nix provides a more minimal set)
  environment.systemPackages = with pkgs; [
    # System tools
    lsof
    htop
    iotop
    # dool # Consider if this is needed; sysstat is more common
    sysstat # for iostat, mpstat etc.
    tcpdump
    iptables # For viewing/diagnosing firewall rules, even if nftables is the backend

    # K3s package itself is typically pulled in when services.k3s is enabled in a role.
    # Tailscale package is typically pulled in when services.tailscale is enabled in its module.
    # Infisical package/binary would be handled by its module if it provides one.

    # File tools
    file
    tree
    ncdu
    ripgrep
    fd

    # Network tools
    inetutils # Provides ping, hostname, etc. (Some tools may overlap with busybox in initrd)
    mtr
    nmap
    socat

    # Process management
    psmisc # Provides pstree, killall, etc.
    procps # Provides ps, top, free, etc.

    # Text processing
    jq
    yq-go # Using go version of yq as it's often preferred
  ];

  # ----- Server-Specific Service Configuration -----
  services.openssh = {
    enable = true; # Ensure SSHD is running on servers
    settings = {
      X11Forwarding = false;
      AllowTcpForwarding = true; # Useful for kubectl port-forward, etc. Review security implications.
      PermitRootLogin = "prohibit-password"; # Root login with key only (key setup in common.nix)
      PasswordAuthentication = false; # Disable password-based SSH login entirely
      KbdInteractiveAuthentication = false; # Disable keyboard-interactive auth (often implies passwords)
      MaxAuthTries = 3;
      # Consider uncommenting and adjusting these for keep-alive:
      # ClientAliveInterval = 300;
      # ClientAliveCountMax = 2;
    };
  };

  # Security hardening for servers
  security.auditd.enable = true; # Enable audit daemon
  security.audit.enable = true; # Enable kernel audit system (used by auditd)

  # Networking (useDHCP=false for servers, useNetworkd for explicit config)
  networking.useDHCP = lib.mkDefault false; # Servers typically have static or well-defined IP configurations
  networking.useNetworkd = true; # Use systemd-networkd for network configuration
  systemd.network.enable = true; # Ensure the service itself is enabled

  networking.firewall = {
    # Specific firewall rules can be added by roles/locations or further down here
    allowPing = true;
    logReversePathDrops = true;
    # Example for K3s (ports would be opened based on roles - control plane vs worker):
    # allowedTCPPorts = [ 22 6443 ]; # Example: SSH and K3s API
    # allowedUDPPorts = [ ... ];
  };

  # Disable services typically not needed on a headless server
  services.xserver.enable = false;
  services.printing.enable = false;
  hardware.bluetooth.enable = false;
  sound.enable = false;
}
