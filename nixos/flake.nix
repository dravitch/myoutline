{
  description = "Outline + PocketID — NixOS natif, sans Docker";

  inputs = {
    # nixos-unstable requis pour services.pocket-id
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
    nixosConfigurations.outline-server = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hardware-configuration.nix
        ./configuration.nix
      ];
    };
  };
}
