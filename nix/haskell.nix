# Haskell project wiring: dev shells (via the haskell-nix-dev base flake) and the
# project package (via callCabal2nix). seihou-managed — to add project-specific
# dev tools without editing this file, set `haskellProject.extraDevPackages` from
# ./flake.module.nix (see flake.module.nix.example).
{ inputs, lib, flake-parts-lib, ... }:
{
  options.perSystem = flake-parts-lib.mkPerSystemOption ({ ... }: {
    options.haskellProject.extraDevPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.ghciwatch pkgs.haskellPackages.hpack ]";
      description = ''
        Extra packages to add to the dev shell. Set this from ./flake.module.nix
        to add project-specific tooling without editing the generated
        ./nix/haskell.nix.
      '';
    };
  });

  config.perSystem = { system, pkgs, config, ... }:
    let
      hsdev = inputs.haskell-nix-dev.lib.${system};
      haskellPackages = pkgs.haskell.packages."ghc9124";

      baseDevPackages = [
        pkgs.zlib
        pkgs.just
        pkgs.pkg-config
        # PostgreSQL 18 specifically, not the nixpkgs default. keiro-migrations
        # 0.13 embeds a PG 18 schema snapshot and its verifyExpectedSchema
        # refuses any other major version outright, so on PG 17 every keiro-ops
        # verb mounted into the `shikigami` binary -- including the read-only
        # ones -- fails before it runs. See
        # docs/plans/30-operator-cli-inspect-runs-agents-dead-letters-and-cancel.md.
        pkgs.postgresql_18
        pkgs.jq
        pkgs.process-compose
      ];

      shellHook = ''
        ${config.pre-commit.installationScript}

        export PGHOST="$PWD/db"
        export PGDATA="$PGHOST/db"
        export PGLOG=$PGHOST/postgres.log
        export PGDATABASE=shikigami
        export PG_CONNECTION_STRING=postgresql://$(jq -rn --arg x $PGHOST '$x|@uri')/$PGDATABASE

        mkdir -p $PGHOST
        mkdir -p .dev

        if [ ! -d $PGDATA ]; then
          initdb --auth=trust --no-locale --encoding=UTF8
        fi
      '';

      mkProjectShell = ghc: hsdev.mkDevShell {
        inherit ghc;
        extraNativeBuildInputs = baseDevPackages ++ config.haskellProject.extraDevPackages;
        withHls = true;
        inherit shellHook;
      };
    in
    {
      packages.default = haskellPackages.callCabal2nix "shikigami" inputs.self { };

      devShells.default = mkProjectShell "ghc9124";
      devShells."ghc9124" = mkProjectShell "ghc9124";
    };
}
