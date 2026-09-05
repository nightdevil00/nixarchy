# Home Manager configuration for the mihai user.
{ config, lib, pkgs, nixarchy, ... }:

{
  imports = [
    nixarchy.homeManagerModules.nixarchy
  ];

  home.username = "mihai";
  home.homeDirectory = "/home/mihai";

  programs.nixarchy.enable = true;

  home.stateVersion = "26.05";

  # Let Home Manager install and manage itself when run via NixOS.
  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    git
  ];
}
