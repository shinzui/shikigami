# Build one frozen Cabal graph, including all seven application packages. The
# source lock is generated from the qualified solve, not an independent Nix solve.
{ pkgs, lib, source, gitRev, workspaceFixture ? null, dependenciesOnly ? false, buildCache ? null }:
let
  effectiveRev = if dependenciesOnly then "dependencies" else gitRev;
  lock = builtins.fromJSON (builtins.readFile ./qualification/cohort.json);
  deadlineGuard = import ./workspace-deadline.nix { inherit pkgs; };
  repositories = lib.mapAttrs (_: pin: builtins.fetchTree pin) lock.repositories;
  packageNames = builtins.attrNames lock.packages;
  stagePackage = name:
    let
      package = lock.packages.${name};
      src = package.source;
      destination = "packages/${name}";
    in
    if src.type == "local" then
      if dependenciesOnly then
        let manifest = builtins.path { path = source + "/${src.path}/${name}.cabal"; name = "qualification-${name}.cabal"; };
        in ''
          mkdir -p ${destination}
          cp ${manifest} ${destination}/${name}.cabal
        ''
      else ''
        cp -R ${source}/${src.path} ${destination}
      ''
    else if src.type == "hackage" then
      let archive = pkgs.fetchurl { inherit (src) url hash; };
      in ''
        mkdir -p ${destination}
        tar -xzf ${archive} --strip-components=1 -C ${destination}
        cp metadata/${name}.cabal ${destination}/${name}.cabal
      ''
    else if src.type == "github" then ''
      cp -R ${repositories.${src.repository}.outPath}/${src.subdir} ${destination}
    ''
    else if src.type == "vendored" then
      let archive = ./qualification + "/${src.path}";
      in assert builtins.hashFile "sha256" archive == src.sha256; ''
        mkdir -p ${destination}
        tar -xf ${archive} --strip-components=1 -C ${destination} ${src.subdir}
      ''
    else throw "unsupported qualification source ${src.type}";
  # Restore pre-restriction descriptor bytes before rechecking the frozen solve.
  restoreDescriptor = name:
    let
      src = lock.packages.${name}.source;
      destination = "packages/${name}/${name}.cabal";
    in
    if src.type == "hackage" then ''
      cp metadata/${name}.cabal ${destination}
    '' else if src.type == "github" then
      let manifest = builtins.path { path = repositories.${src.repository}.outPath + "/${src.subdir}/${name}.cabal"; name = "qualification-original-${name}.cabal"; };
      in ''
        cp ${manifest} ${destination}
      ''
    else if src.type == "vendored" then ''
      tar -xOf ${./qualification + "/${src.path}"} ${src.subdir}/${name}.cabal > ${destination}
    '' else throw "unsupported cached descriptor source ${src.type}";
  project = pkgs.writeText "qualification-cabal.project" (''
    packages: packages/*/*.cabal
    active-repositories: :none
    with-compiler: ghc-9.12.4
    tests: False
    benchmarks: False
    allow-newer: claude:http-client-tls, kiroku-cli:http-client-tls
  '' + lib.concatMapStrings
    (name:
      let
        flags = lock.packages.${name}.flags;
        flagNames = builtins.attrNames flags;
      in
      lib.optionalString (flagNames != [ ]) (
        ''
          package ${name}
            flags: ${lib.concatMapStringsSep " " (flag: (if flags.${flag} then "+" else "-") + flag) flagNames}
        ''
      ))
    packageNames + ''
    package blake3
      ghc-options: -optc-DBLAKE3_USE_NEON=0
    package shikigami-migrations
      ghc-options: "-DGIT_HASH=\"${effectiveRev}\""
    package shikigami-client
      ghc-options: "-DGIT_HASH=\"${effectiveRev}\""
    package shikigami-core
      ghc-options: "-DGIT_HASH=\"${effectiveRev}\""
  '');
  applicationPackages = builtins.filter (name: lib.hasPrefix "shikigami-" name) packageNames;
  prototypeExecutables = [ "shikigami" "shikigami-migrate" "shikigami-workspace-collector" "shikigami-workspace-supervisor" ];
  buildTargets =
    if workspaceFixture == null || dependenciesOnly then applicationPackages ++ lib.optional (workspaceFixture != null) "workspace-linux-fixture"
    else map (name: "exe:${name}") (prototypeExecutables ++ [ "shikigami-workspace-prototype" ]);
in
assert lock.compiler == "ghc-9.12.4";
assert builtins.length applicationPackages == 7;
pkgs.stdenv.mkDerivation {
  pname = if dependenciesOnly then "shikigami-qualification-dependencies" else if workspaceFixture == null then "shikigami-runtime" else "shikigami-workspace-prototype";
  version = "0.1.0.0-${effectiveRev}";
  dontUnpack = true;
  # Match mori://NixOS/nixpkgs, path
  # pkgs/development/haskell-modules/generic-builder.nix (artifact URI pending):
  # compile-time text embedding also decodes through the locale.
  env = { LANG = "en_US.UTF-8"; }
    // lib.optionalAttrs (pkgs.stdenv.buildPlatform.libc == "glibc") {
    LOCALE_ARCHIVE = "${pkgs.buildPackages.glibcLocales}/lib/locale/locale-archive";
  };
  nativeBuildInputs = [ pkgs.haskell.compiler.ghc9124 pkgs.cabal-install pkgs.pkg-config pkgs.git pkgs.python3 ];
  buildInputs = [ pkgs.zlib pkgs.rdkafka pkgs.postgresql_18 pkgs.postgresql_18.dev pkgs.openssl.dev pkgs.curl.dev ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.systemd.dev ];
  configurePhase = ''
    runHook preConfigure
    export CABAL_DIR="$TMPDIR/cabal"
    export HOME="$TMPDIR/home"
    export GHC_ENVIRONMENT=-
    ${lib.optionalString (buildCache != null) ''
      tar -xzf ${buildCache}/build-cache.tar.gz
      chmod -R u+w packages dist-newstyle cabal home metadata
      # Application sources are always replaced, including deleted files.
      ${lib.concatMapStrings (name: "rm -rf packages/${name}\n") applicationPackages}
      rm -rf packages/workspace-linux-fixture
    ''}
    mkdir -p "$CABAL_DIR" "$HOME" packages metadata
    tar -xzf ${./qualification/metadata.tar.gz} -C metadata
    touch "$CABAL_DIR/config"
    ${if buildCache == null then lib.concatMapStrings stagePackage packageNames else lib.concatMapStrings restoreDescriptor (builtins.filter (name: !(builtins.elem name applicationPackages)) packageNames) + lib.concatMapStrings stagePackage applicationPackages}
    ${lib.optionalString (workspaceFixture != null) (
      if dependenciesOnly then
        let manifest = builtins.path { path = workspaceFixture + "/workspace-linux-fixture.cabal"; name = "qualification-workspace-linux-fixture.cabal"; };
        in ''
          mkdir -p packages/workspace-linux-fixture
          cp ${manifest} packages/workspace-linux-fixture/workspace-linux-fixture.cabal
        ''
      else ''
        cp -R ${workspaceFixture} packages/workspace-linux-fixture
      ''
    )}
    chmod -R u+w packages
    cp ${project} cabal.project
    cp ${./qualification/cohort.json} cohort.json
    python3 ${../tools/qualification/verify-cohort.py} --lock cohort.json --packages packages --restrict-components
    runHook postConfigure
  '';
  buildPhase = ''
    runHook preBuild
    cabal build --offline ${lib.optionalString dependenciesOnly "--only-dependencies"} -j"$NIX_BUILD_CORES" ${lib.concatStringsSep " " buildTargets}
    runHook postBuild
  '';
  installPhase =
    if dependenciesOnly then ''
      runHook preInstall
      mkdir -p "$out"
      tar -czf "$out/build-cache.tar.gz" packages dist-newstyle cabal home metadata
      cp cohort.json "$out/cohort.json"
      runHook postInstall
    '' else ''
      runHook preInstall
      mkdir -p "$out/bin" "$out/share/shikigami"
      ln -s ${deadlineGuard}/bin/shikigami-workspace-deadline "$out/bin/shikigami-workspace-deadline"
      for executable in ${if workspaceFixture != null then lib.concatStringsSep " " prototypeExecutables else ''shikigami shikigami-server shikigami-worker shikigami-migrate \
        shikigami-scheduler shikigami-consume-stream shikigami-consume-events \
        shikigami-agent-run shikigami-run-behavior shikigami-agent-launch shikigami-openapi shikigami-client \
        shikigami-workspace-collector shikigami-workspace-supervisor''}; do
        cp "$(cabal list-bin --offline exe:$executable)" "$out/bin/$executable"
        case "$executable" in
          shikigami-openapi|shikigami-workspace-collector|shikigami-workspace-supervisor) ;;
          *)
            mkdir -p "$out/share/bash-completion/completions" "$out/share/zsh/site-functions" "$out/share/fish/vendor_completions.d"
            "$out/bin/$executable" --bash-completion-script "$out/bin/$executable" +RTS -N2 -RTS > "$out/share/bash-completion/completions/$executable"
            "$out/bin/$executable" --zsh-completion-script "$out/bin/$executable" +RTS -N2 -RTS > "$out/share/zsh/site-functions/_$executable"
            "$out/bin/$executable" --fish-completion-script "$out/bin/$executable" +RTS -N2 -RTS > "$out/share/fish/vendor_completions.d/$executable.fish"
            ;;
        esac
      done
      ${lib.optionalString (workspaceFixture != null) ''
        cp "$(cabal list-bin --offline exe:shikigami-workspace-prototype)" "$out/bin/shikigami-workspace-prototype"
      ''}
      cp -R ${source}/schema "$out/share/shikigami/schema"
      mkdir -p "$out/share/shikigami/agents/proof"
      cp ${source}/agents/proof/shikumi-judgment-example.dhall \
        "$out/share/shikigami/agents/proof/shikumi-judgment-example.dhall"
      mkdir -p "$out/share/shikigami/fixtures"
      cp -R ${source}/fixtures/qualification "$out/share/shikigami/fixtures/qualification"
      chmod -R u+w "$out/share/shikigami/fixtures"
      substituteInPlace "$out/share/shikigami/fixtures/qualification/agents/service-health-reporter.dhall" \
        "$out/share/shikigami/fixtures/qualification/agents/service-health-observer.dhall" \
        --replace-fail "fixtures/qualification/skills/service-health" "$out/share/shikigami/fixtures/qualification/skills/service-health"
      cp -R ${source}/shikigami-api/test/hurl "$out/share/shikigami/api-hurl"
      cp cohort.json "$out/share/shikigami/cohort.json"
      runHook postInstall
    '';
  passthru = { inherit applicationPackages; };
  meta.platforms = [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ];
}
