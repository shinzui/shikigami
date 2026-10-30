# Build one frozen Cabal graph, including all seven application packages. The
# source lock is generated from the qualified solve, not an independent Nix solve.
{ pkgs, lib, source, gitRev, workspaceFixture ? null }:
let
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
    if src.type == "local" then ''
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
  project = pkgs.writeText "qualification-cabal.project" (''
    packages: packages/*/*.cabal
    active-repositories: :none
    with-compiler: ghc-9.12.4
    tests: False
    benchmarks: False
    allow-newer: claude:http-client-tls, pg-migrate-test-support:ephemeral-pg
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
      ghc-options: "-DGIT_HASH=\"${gitRev}\""
    package shikigami-client
      ghc-options: "-DGIT_HASH=\"${gitRev}\""
    package shikigami-core
      ghc-options: "-DGIT_HASH=\"${gitRev}\""
  '');
  applicationPackages = builtins.filter (name: lib.hasPrefix "shikigami-" name) packageNames;
in
assert lock.compiler == "ghc-9.12.4";
assert builtins.length applicationPackages == 7;
pkgs.stdenv.mkDerivation {
  pname = if workspaceFixture == null then "shikigami-runtime" else "shikigami-workspace-prototype";
  version = "0.1.0.0-${gitRev}";
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
    mkdir -p "$CABAL_DIR" "$HOME" packages metadata
    tar -xzf ${./qualification/metadata.tar.gz} -C metadata
    touch "$CABAL_DIR/config"
    ${lib.concatMapStrings stagePackage packageNames}
    ${lib.optionalString (workspaceFixture != null) ''
      cp -R ${workspaceFixture} packages/workspace-linux-fixture
    ''}
    chmod -R u+w packages
    cp ${project} cabal.project
    cp ${./qualification/cohort.json} cohort.json
    python3 ${../tools/qualification/verify-cohort.py} --lock cohort.json --packages packages --restrict-components
    runHook postConfigure
  '';
  buildPhase = ''
    runHook preBuild
    cabal build --offline -j"$NIX_BUILD_CORES" ${lib.concatStringsSep " " applicationPackages} ${lib.optionalString (workspaceFixture != null) "workspace-linux-fixture"}
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/share/shikigami"
    ln -s ${deadlineGuard}/bin/shikigami-workspace-deadline "$out/bin/shikigami-workspace-deadline"
    for executable in shikigami shikigami-server shikigami-worker shikigami-migrate \
      shikigami-scheduler shikigami-consume-stream shikigami-consume-events \
      shikigami-agent-run shikigami-run-behavior shikigami-agent-launch shikigami-openapi shikigami-client \
      shikigami-workspace-collector shikigami-workspace-supervisor; do
      cp "$(cabal list-bin --offline exe:$executable)" "$out/bin/$executable"
    done
    ${lib.optionalString (workspaceFixture != null) ''
      cp "$(cabal list-bin --offline exe:shikigami-workspace-prototype)" "$out/bin/shikigami-workspace-prototype"
    ''}
    cp -R ${source}/schema "$out/share/shikigami/schema"
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
