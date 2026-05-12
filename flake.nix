{
  description = "Ubuntu Server AI coding VM managed with Nix System Manager";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    system-manager = {
      url = "github:numtide/system-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, system-manager, ... }:
    {
      systemConfigs.default = system-manager.lib.makeSystemConfig {
        modules = [
          ./system.nix
        ];
      };
    };
}
