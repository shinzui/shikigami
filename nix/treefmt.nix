# treefmt-nix as a flake-parts module. This automatically wires `nix fmt`
# (the flake `formatter`) and a `treefmt` flake check. seihou-managed.
{ inputs, ... }:
{
  imports = [ inputs.treefmt-nix.flakeModule ];

  perSystem = { ... }: {
    treefmt = {
      projectRootFile = "flake.nix";
      programs.nixpkgs-fmt.enable = true;
      programs.fourmolu.enable = true;
      # Keiro's scaffold gate checks these machine-owned bytes. Hand-owned
      # BehaviorHoles and ReadModelHoles remain under ordinary formatting.
      settings.formatter.fourmolu.excludes = [
        "shikigami-core/src/Shikigami/Generated/*"
        "shikigami-core/src/Shikigami/*/Generated/*"
        "shikigami-core/src/keiro-dsl-conformance.workspace.*/src/Main.hs"
      ];
      # cabal-gild (github.com/tfausak/cabal-gild) formats *.cabal plus
      # cabal.project/cabal.project.local, and can discover module lists from
      # the filesystem via `-- cabal-gild: discover <dir>` pragmas.
      programs.cabal-gild.enable = true;
      settings.formatter.cabal-gild.excludes = [
        "shikigami-core/src/keiro-dsl-conformance.workspace.*/*.cabal"
      ];
    };
  };
}
