{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Local machine specific configuration

  # Use NetworkManager for networking on local machines
  networking = {
    useDHCP = false;
    networkmanager.enable = true;
  };

  # Enable DHCP on all interfaces by default
  # Override this in the hardware-configuration.nix if needed
  networking.interfaces = lib.mkDefault {
    # This is a placeholder that will be overridden by hardware-configuration.nix
  };

  # Local machine specific boot settings
  boot.loader = {
    systemd-boot = {
      enable = true;
      configurationLimit = 10;
    };
    efi.canTouchEfiVariables = true;
  };

  # Enable firmware updates
  hardware.enableRedistributableFirmware = true;

  # Disable non-redistributable firmware for now
  # hardware.enableAllFirmware = true;

  # Enable CPU microcode updates
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # Enable fstrim for SSDs
  services.fstrim.enable = true;

  # Enable smartd for disk monitoring
  services.smartd = {
    enable = true;
    autodetect = true;
    notifications.mail.enable = false;
  };

  # Enable thermald for thermal management
  services.thermald.enable = true;

  # Enable TLP for power management
  services.tlp.enable = true;

  # Enable powertop
  powerManagement.powertop.enable = true;

  # Enable auto-cpufreq
  services.auto-cpufreq.enable = true;

  # Enable firewall
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ]; # SSH
    allowPing = true;
  };

  # Enable avahi for local network discovery
  services.avahi = {
    enable = true;
    nssmdns = true;
    publish = {
      enable = true;
      addresses = true;
      domain = true;
      hinfo = true;
      userServices = true;
      workstation = true;
    };
  };

  # Enable mDNS
  services.resolved = {
    enable = true;
    dnssec = "false";
    domains = [ "~." ];
    fallbackDns = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    extraConfig = ''
      MulticastDNS=yes
    '';
  };

  # Enable NTP
  services.timesyncd.enable = true;

  # Set timezone to local timezone (override in hardware-configuration.nix if needed)
  time.timeZone = lib.mkDefault "America/Denver";
}
