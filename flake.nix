{
  description = "Mihai's NixOS with Omarchy (nixarchy)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixarchy.url = "github:olafkfreund/nixarchy/v4.0.2-5";
  };

  outputs = { self, nixpkgs, home-manager, nixarchy, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit nixarchy; };
        modules = [
          ./configuration.nix

          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit nixarchy; };
            home-manager.users.mihai = import ./home.nix;
          }
        ];
      };
    };
}
