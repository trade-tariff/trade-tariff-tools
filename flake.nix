{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      pre-commit-hooks,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        runtimeDeps = [
          pkgs.awscli2
          pkgs.jq
          pkgs.fzf
          pkgs.gh
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
        reviewBats = pkgs.bats.overrideAttrs (_: {
          version = "1.10.0";
          src = pkgs.fetchFromGitHub {
            owner = "bats-core";
            repo = "bats-core";
            rev = "f7defb94362f2053a3e73d13086a167448ea9133";
            hash = "sha256-gy4dyoKRlf2WFmH1/mSNwhVR3df92BgpT4TjTpV4FyQ=";
          };
        });

        reviewEnvironment = ''
          if [ "''${REVIEW_SANDBOX:-}" != 1 ] || [ "$PWD" != /workspace ]; then exit 64; fi
          export TMPDIR=/workspace/.review/tmp PRE_COMMIT_HOME=/workspace/.review/pre-commit
          export npm_config_ignore_scripts=true YARN_IGNORE_SCRIPTS=true YARN_OFFLINE=true YARN_CACHE_FOLDER="$TMPDIR/yarn-cache"
          export CI=true AWS_EC2_METADATA_DISABLED=true
          mkdir -p "$TMPDIR"
        '';

        reviewTools = import (builtins.fetchTree {
          type = "github";
          owner = "NixOS";
          repo = "nixpkgs";
          rev = "4a29d733e8a7d5b824c3d8c958a946a9867b3eb2";
          narHash = "sha256-f+JACbTqzZ+G92DSnXOUGRhGANb8Blh7CoeYOeBF8/U=";
        }) { inherit system; };
        reviewSecretTools = import (builtins.fetchTree {
          type = "github";
          owner = "NixOS";
          repo = "nixpkgs";
          rev = "b86751bc4085f48661017fa226dee99fab6c651b";
          narHash = "sha256-a8BYi3mzoJ/AcJP8UldOx8emoPRLeWqALZWu4ZvjPXw=";
        }) { inherit system; };
        reviewPreCommitConfig = pkgs.writeText "review-pre-commit.json" (
          builtins.toJSON {
            repos = [
              {
                repo = "local";
                hooks = [
                  {
                    id = "trailing-whitespace";
                    name = "trim trailing whitespace";
                    language = "system";
                    entry = "${reviewTools.python3Packages.pre-commit-hooks}/bin/trailing-whitespace-fixer";
                    types = [ "text" ];
                    stages = [
                      "pre-commit"
                      "pre-push"
                      "manual"
                    ];
                  }
                  {
                    id = "end-of-file-fixer";
                    name = "fix end of files";
                    language = "system";
                    entry = "${reviewTools.python3Packages.pre-commit-hooks}/bin/end-of-file-fixer";
                    types = [ "text" ];
                    stages = [
                      "pre-commit"
                      "pre-push"
                      "manual"
                    ];
                  }
                  {
                    id = "check-yaml";
                    name = "check yaml";
                    language = "system";
                    entry = "${reviewTools.python3Packages.pre-commit-hooks}/bin/check-yaml";
                    types = [ "yaml" ];
                  }
                  {
                    id = "check-merge-conflict";
                    name = "check for merge conflicts";
                    language = "system";
                    entry = "${reviewTools.python3Packages.pre-commit-hooks}/bin/check-merge-conflict";
                    types = [ "text" ];
                  }
                  {
                    id = "shellcheck";
                    name = "ShellCheck v0.11.0";
                    language = "system";
                    entry = "${reviewTools.shellcheck}/bin/shellcheck";
                    types = [ "shell" ];
                    args = [ "--severity=error" ];
                  }
                  {
                    id = "actionlint-docker";
                    name = "Lint GitHub Actions workflow files";
                    language = "system";
                    entry = "${reviewTools.actionlint}/bin/actionlint";
                    types = [ "yaml" ];
                    files = "^\\.github/workflows/";
                  }
                  {
                    id = "trufflehog";
                    name = "TruffleHog";
                    language = "system";
                    entry = "${reviewSecretTools.trufflehog}/bin/trufflehog git file://. --since-commit HEAD --results=verified --fail --trust-local-git-config";
                    pass_filenames = false;
                  }
                ];
              }
            ];
          }
        );

        preCommitCheck = pre-commit-hooks.lib.${system}.run {
          src = ./.;
          configPath = ".pre-commit-config-nix.yaml";
          default_stages = [ "pre-commit" ];
          hooks = {
            actionlint = {
              enable = true;
              stages = [ "pre-commit" ];
            };
            check-added-large-files = {
              enable = true;
              stages = [ "pre-commit" ];
            };
            check-case-conflicts = {
              enable = true;
              stages = [ "pre-commit" ];
            };
            check-merge-conflicts = {
              enable = true;
              stages = [ "pre-commit" ];
            };
            check-yaml = {
              enable = true;
              stages = [ "pre-commit" ];
            };
            deadnix = {
              enable = true;
              stages = [ "pre-commit" ];
            };
            detect-private-keys = {
              enable = true;
              stages = [ "pre-commit" ];
            };
            nixfmt-rfc-style = {
              package = pre-commit-hooks.inputs.nixpkgs.legacyPackages.${system}.nixfmt;
              enable = true;
              stages = [ "pre-commit" ];
            };
            shellcheck = {
              enable = true;
              args = [ "--severity=error" ];
              stages = [ "pre-commit" ];
            };
            statix = {
              enable = true;
              settings.ignore = [ "{.direnv,.nix,.worktrees}/**" ];
              stages = [ "pre-commit" ];
            };
            trufflehog = {
              enable = true;
              stages = [ "pre-commit" ];
            };
          };
        };

        preCommit = pkgs.writeShellScriptBin "pre-commit" ''
          set -euo pipefail

          has_config=false
          for arg in "$@"; do
            case "$arg" in
              -c|--config|--config=*)
                has_config=true
                ;;
            esac
          done

          if [ "$has_config" = true ]; then
            exec ${preCommitCheck.config.package}/bin/pre-commit "$@"
          fi

          if [ "''${1:-}" = "run" ]; then
            shift
            exec ${preCommitCheck.config.package}/bin/pre-commit run --config .pre-commit-config-nix.yaml "$@"
          fi

          exec ${preCommitCheck.config.package}/bin/pre-commit "$@"
        '';
      in
      {
        packages.default = ecs;
        packages.ecs = ecs;
        devShells.review = self.devShells.${system}.default.overrideAttrs (old: {
          shellHook = "";
          nativeBuildInputs = [
            pkgs.gitMinimal
            reviewBats
            pkgs.nodejs_24
            pkgs.yarn
            pkgs.ruby
            pkgs.curl
            pkgs.jq
            (pkgs.python3.withPackages (ps: [
              ps.requests
              ps.openpyxl
            ]))
            reviewTools.pre-commit
            (pkgs.writeShellApplication {
              name = "review-bootstrap";
              text = reviewEnvironment + ''
                printf 'yarn-offline-mirror "/deps/yarn-archives"\n' > "$TMPDIR/yarnrc"
                yarn --use-yarnrc "$TMPDIR/yarnrc" install --offline --frozen-lockfile --ignore-scripts
              '';
            })
            (pkgs.writeShellApplication {
              name = "review-check";
              text = reviewEnvironment + ''
                status=0
                pre-commit run --all-files --config ${reviewPreCommitConfig} || status=$?
                for file in bin/* scripts/*.sh scripts/lib/*.sh .github/actions/*/*.sh tests/test_helper.bash; do bash -n "$file" || status=$?; done
                bats --tap --print-output-on-failure tests | tee "$TMPDIR/bats.log" || status=$?
                if grep -E '# skip' "$TMPDIR/bats.log"; then status=1; fi
                yarn test --runInBand --json --outputFile="$TMPDIR/unit.json" || status=$?
                jq -e '.numTotalTests > 0 and .numFailedTests == 0 and .numPendingTests == 0 and .wasInterrupted == false' "$TMPDIR/unit.json" || status=$?
                exit "$status"
              '';
            })
          ]
          ++ (old.nativeBuildInputs or [ ]);
          TZDIR = "${pkgs.tzdata.outPath}/share/zoneinfo";
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        });

        devShells.default = pkgs.mkShell {
          shellHook = ''
            ${preCommitCheck.shellHook}
            export PATH=${preCommit}/bin:$PATH
          '';

          buildInputs = preCommitCheck.enabledPackages ++ runtimeDeps;
        };
      }
    );
}
