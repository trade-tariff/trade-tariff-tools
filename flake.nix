{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        ecs = pkgs.stdenv.mkDerivation {
          pname = "ecs";
          version = "0.1.0";
          src = ./.;

          installPhase = ''
            mkdir -p $out/bin
            install -m 755 bin/ecs $out/bin/ecs
          '';

          meta = with pkgs.lib; {
            description = "Interactive tool for running commands in ECS tasks";
            license = licenses.mit;
          };
        };
      in
      {
        packages.default = ecs;
        packages.ecs = ecs;
      }
    );
}
