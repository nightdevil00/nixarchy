# Configuration for the NixOS host. Includes nixarchy (Omarchy) and
# replaces the GNOME/GDM desktop with Omarchy's Hyprland behind SDDM.
{ config, lib, pkgs, nixarchy, ... }:

{
  imports =
    [
      # Include the results of the hardware scan.
      ./hardware-configuration.nix
      nixarchy.nixosModules.nixarchy
    ];

  ##########################################################################
  # Omarchy (nixarchy)
  ##########################################################################
  programs.nixarchy = {
    enable = true;
    user = "mihai";
  };

  # The doctor reported gdm is currently greeting. The user chose to replace
  # it with nixarchy's SDDM, so displayManager stays at its default (true)
  # and GDM/GNOME below are disabled -- two display managers at once refuses
  # to build.

  ##########################################################################
  # Bootloader.
  ##########################################################################
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "nixos";
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "Europe/Bucharest";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "ro_RO.UTF-8";
    LC_IDENTIFICATION = "ro_RO.UTF-8";
    LC_MEASUREMENT = "ro_RO.UTF-8";
    LC_MONETARY = "ro_RO.UTF-8";
    LC_NAME = "ro_RO.UTF-8";
    LC_NUMERIC = "ro_RO.UTF-8";
    LC_PAPER = "ro_RO.UTF-8";
    LC_TELEPHONE = "ro_RO.UTF-8";
    LC_TIME = "ro_RO.UTF-8";
  };

  # Omarchy provides its own Wayland session via SDDM. GDM and the GNOME
  # desktop are removed -- nixarchy's SDDM greeter replaces them.
  services.desktopManager.gnome.enable = lib.mkForce false;
  services.displayManager.gdm.enable = lib.mkForce false;

  # Configure keymap.
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  ##########################################################################
  # Graphics -- Intel + NVIDIA hybrid, sync mode (doctor recommendation).
  ##########################################################################
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [ intel-media-driver ];
  };

  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    modesetting.enable = true;
    open = true;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  hardware.nvidia.prime = {
    sync.enable = true;
    intelBusId = "PCI:0:2:0";
    nvidiaBusId = "PCI:1:0:0";
  };

  ##########################################################################
  # Kernel -- latest stable.
  ##########################################################################
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Define a user account.
  users.users."mihai" = {
    isNormalUser = true;
    description = "Mihai";
    extraGroups = [ "networkmanager" "wheel" "input" ];
    packages = with pkgs; [
      git
      wget
      curl
      opencode
      google-chrome
    ];
  };

  # Install firefox.
  programs.firefox.enable = true;

  # Passwordless sudo for the wheel group
  security.sudo.wheelNeedsPassword = false;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile.
  environment.systemPackages = with pkgs; [
    git
    wget
    curl
    vim
  ];

  system.stateVersion = "26.05";
}
