# /home/evan/2_Dev/2.1_Homelab/!k3s-nixos-configs/k3s-cluster/modules/netdata.nix
{
  config,
  lib,
  pkgs,
  specialArgs ? { },
  ...
}:

let
  # --- Configurable Access Control ---
  # Define who can access the Netdata dashboard.
  # Defaults to a restrictive set: localhost and common private/Tailscale ranges.
  # This can be overridden by passing `netdataAllowedSources = [ ... ]` in `specialArgs`
  # when this module is imported by a NixOS configuration in your Flake.
  defaultAllowedSources = [
    "localhost" # Always allow local access for diagnostics
    "10.0.0.0/8" # Common private RFC1918 range (covers Hetzner private net)
    "172.16.0.0/12" # Common private RFC1918 range
    "192.168.0.0/16" # Common private RFC1918 range
    "100.64.0.0/10" # Tailscale CGNAT range
    "fd00::/8" # Tailscale IPv6 ULA range
    # Example: Add a specific admin IP if needed and known
    # (if specialArgs.adminPublicIp != null then specialArgs.adminPublicIp else "127.0.0.1") # Safely default if not set
  ];

  # Use provided list or fall back to defaults
  allowedSourcesList = specialArgs.netdataAllowedSources or defaultAllowedSources;

  # Convert the list to a space-separated string required by Netdata config
  allowedSourcesConfigString = lib.concatStringsSep " " allowedSourcesList;

  # --- Configurable Performance/Storage ---
  updateInterval = specialArgs.netdataUpdateInterval or 2; # Seconds, increased from 1 to slightly reduce load
  pageCacheSizeMB = specialArgs.netdataPageCacheSizeMb or 32; # MB
  dbengineDiskSpaceMB = specialArgs.netdataDbengineDiskSpaceMb or 256; # MB
  historySeconds = specialArgs.netdataHistorySeconds or 7200; # Default 2 hours of metrics (was 3600)

in
{
  services.netdata = {
    enable = true;
    package = pkgs.netdata; # Explicitly use the version from nixpkgs

    # Core Netdata configuration
    config = {
      global = {
        "update every" = updateInterval;
        "memory mode" = "dbengine"; # Efficient storage, good for servers
        "page cache size" = pageCacheSizeMB;
        "dbengine multihost disk space" = dbengineDiskSpaceMB;
        "history" = historySeconds; # How long to keep metrics
        # Consider error log settings for production
        # "error log" = "/var/log/netdata/error.log";
        # "debug log" = "/var/log/netdata/debug.log"; # Usually none for production
      };

      web = {
        "default port" = 19999;
        # Secure access to the dashboard
        "allow connections from" = allowedSourcesConfigString;
        "allow dashboard from" = allowedSourcesConfigString;
        # Further restrict access to the config file itself
        "allow netdata.conf from" = "localhost unixdomain";
        # Consider disabling web stats if not needed
        # "web server statistics" = "no";
      };

      plugins = {
        # Core system monitoring plugins (generally useful)
        "apps" = true; # Per-application resource usage
        "cgroups" = true; # Essential for container monitoring (K3s uses containerd)
        "diskspace" = true; # Filesystem usage
        "proc" = true; # Kernel (/proc) based metrics: CPU, net, disk I/O, etc.
        "python.d" = true; # Enable python plugin engine for broader capabilities
        "go.d" = true; # Enable go plugin engine (e.g., for Kubernetes, Docker collectors if present)

        # Plugins to consider disabling on a lean server if not explicitly needed:
        "tc" = false; # Traffic Control, can be resource-intensive/noisy
        # "charts.d" = false; # Older shell-based collectors, usually covered by others
        # "fping" = false;    # If external pinging isn't critical from this node
        # "slabinfo" = false; # Kernel slab allocator, can be verbose
      };

      # Example: Specific collector configuration (Netdata usually auto-detects well)
      # This section allows fine-tuning if auto-detection isn't sufficient or if you
      # want to ensure specific collectors run or are disabled.
      # "plugin:go.d:kubernetes" = { # If go.d plugin has a kubernetes job
      #   "enabled" = "yes";
      #   # "kubelet_url" = "http://127.0.0.1:10255"; # If Kubelet metrics are available
      # };
      # "plugin:cgroups:containerd" = { # If specific containerd settings are needed
      #   "enabled" = "yes";
      # };
    };

    # Python plugin configuration
    python = {
      enable = true; # Enables the python.d.plugin itself
      # `recommendedPythonPackages = true;` installs a broad set of Python libraries
      # for many potential plugins. For a production server, you might want to be more
      # selective if you know which specific python.d plugins you'll use (if any)
      # to keep the closure size smaller.
      # If no specific python.d plugins are planned beyond what Netdata auto-enables,
      # you could consider setting recommendedPythonPackages = false and only add
      # specific dependencies if a python.d chart complains.
      recommendedPythonPackages = true; # Keep for now for broad out-of-the-box data
      # extraPackages = ps: [ ps.psutil ]; # Example if a specific plugin needed psutil
    };

    # Disable sending anonymous usage statistics to Netdata
    enableAnalyticsReporting = false;
  };

  # Ensure the NixOS host firewall allows access to Netdata's port
  # This should be from the same sources as defined in `allowedSourcesConfigString`.
  # However, NixOS firewall rules are simpler (just port and optionally interface).
  # The actual IP-based restriction is best handled by Netdata itself ("allow connections from")
  # and the cloud firewall (Hetzner Firewall).
  networking.firewall.allowedTCPPorts = [ 19999 ];
}
