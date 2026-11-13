# Use the frozen runtime graph and shared Haskell cases without introducing a
# second solver, test framework or deployment executable. Runtime credentials
# and vendor installations are deliberately absent from this fixture.
{ pkgs, lib, source }:
let
  # Only the fixture is built. Retain the seven local package descriptors for
  # the frozen solve, without making unrelated application/test edits inputs.
  fixtureSource = builtins.path {
    name = "shikigami-baikai-contract-source";
    path = source;
    filter = path: type:
      let relative = lib.removePrefix "${source}/" (toString path);
      in type == "directory"
        || lib.hasSuffix ".cabal" relative
        || lib.hasPrefix "shikigami-core/test-support/" relative
        || lib.hasPrefix "shikigami-core/test-batch/" relative;
  };
  runtime = import ./qualification-package.nix {
    inherit pkgs lib;
    source = fixtureSource;
    # No application library is linked. The derivation's source hash identifies
    # the cases; documentation-only commits need not rebuild their dependencies.
    gitRev = "fixture";
  };
in
runtime.overrideAttrs (previous: {
  pname = "shikigami-baikai-contracts";
  configurePhase = previous.configurePhase + ''
    chmod u+w cabal.project
    printf '\noptional-packages: packages/shikigami-core/test-batch/*.cabal\n' >> cabal.project
  '';
  buildPhase = ''
    runHook preBuild
    cabal build --offline -j"$NIX_BUILD_CORES" exe:shikigami-baikai-contracts
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    cp "$(cabal list-bin --offline exe:shikigami-baikai-contracts)" "$out/bin/"
    cp cohort.json "$out/cohort.json"
    runHook postInstall
  '';
})
