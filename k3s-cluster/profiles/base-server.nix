{
  config,
  lib,
  pkgs,
  inputs ? { },
  ...
}:

{
  imports = [
    ../common.nix
    ../modules/tailscale.nix
    ../modules/infisical-agent.nix
    ../modules/netdata.nix
    # ../../hardware/common/disko/disko-layout.nix # Removed conflicting common import
    # ../../hardware/hetzner/cpx21/disko-layout.nix # Example hardware-specific disko layout
    # ../../hardware/hetzner/cpx21/hardware-configuration.nix  # Example hardware-specific configuration
  ];
  # System configuration
  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  networking.firewall.enable = true;

  # Set up nix
  nix = {
    settings = {
      auto-optimise-store = true;
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [
        "root"
        "@wheel"
      ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  # System packages
  environment.systemPackages = with pkgs; [
    # System tools
    lsof
    htop
    iotop
    dool
    sysstat
    tcpdump
    iptables

    # K3s and related tools
    k3s
    tailscale
    infisical

    # File tools
    file
    tree
    ncdu
    ripgrep
    fd

    # Network tools
    inetutils
    mtr
    nmap
    socat

    # Process management
    psmisc
    procps

    # Text processing
    jq
    yq
  ];

  # Default editor
  environment.variables.EDITOR = "vim";

  # SSH hardening
  services.openssh = {
    settings = {
      X11Forwarding = false;
      AllowTcpForwarding = true;
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      MaxAuthTries = 3;
    };
  };

  # Security hardening
  security = {
    sudo.wheelNeedsPassword = false;
    auditd.enable = true;
    audit.enable = true;
  };

  # Networking
  networking = {
    useDHCP = false;
    useNetworkd = true;
    firewall = {
      allowPing = true;
      logReversePathDrops = true;
    };
  };

  # Enable systemd-networkd
  systemd.network.enable = true;

  # Time synchronization
  services.timesyncd.enable = true;

  # Disable X11
  services.xserver.enable = false;

  # Disable printing
  services.printing.enable = false;

  # Disable bluetooth
  hardware.bluetooth.enable = false;
}
