{
  description = "Guild — agent team orchestration framework";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        haskellPackages = pkgs.haskell.packages.ghc96;
        guild = haskellPackages.callCabal2nix "guild" ./. {};
      in {
        packages.default = guild;

        devShells.default = haskellPackages.shellFor {
          packages = _: [ guild ];
          buildInputs = with pkgs; [
            haskellPackages.cabal-install
            haskellPackages.ghc
            haskellPackages.haskell-language-server
          ];
        };

        apps.default = {
          type = "app";
          program = "${guild}/bin/guild";
        };
      }
    );
}
