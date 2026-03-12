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
        runtimeDeps = [
          pkgs.awscli2
          pkgs.jq
          pkgs.fzf
          pkgs.ssm-session-manager-plugin
        ];
        ecs = pkgs.stdenv.mkDerivation {
          pname = "ecs";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          installPhase = ''
            mkdir -p $out/bin
            install -m 755 bin/ecs $out/bin/ecs
            wrapProgram $out/bin/ecs \
              --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps}
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
