-- The operator's blueprint catalog for the keiro campaign (EP-7 of MasterPlan
-- 22), in the order the campaign applies them: toolchain first, then version
-- edges, then structure. The selection step may name only these; tools.dhall
-- generates the seihou patterns from this list, so no other blueprint runs.
[ { name = "upgrade-haskell-flake-parts"
  , kind = "run"
  , source = "mori://shinzui/seihou-modules"
  , rule = "the manifest records nix-haskell-flake and flake.nix does not yet use the flake-parts layout"
  }
, { name = "fix-nix-haskell-flake-customizations"
  , kind = "run"
  , source = "mori://shinzui/seihou-modules"
  , rule = "the manifest records nix-haskell-flake and flake.nix carries local customizations of it"
  }
, { name = "upgrade-haskell-runtime"
  , kind = "migrate"
  , source = "mori://shinzui/seihou-modules"
  , rule = "only when .seihou/manifest.json already has an upgrade-haskell-runtime receipt (its migrations start at 0.30.0); otherwise skip it and say the operator must adopt the runtime module first"
  }
, { name = "keiro-upgrade"
  , kind = "migrate"
  , source = "mori://shinzui/keiro"
  , rule = "the build resolves keiro below 0.25.0.0; window --from=<resolved version>, target --to=0.25.0.0. It entails kiroku-upgrade and the shibuya adapter edges"
  }
, { name = "shibuya-kiroku-adapter-upgrade"
  , kind = "migrate"
  , source = "mori://shinzui/kiroku"
  , rule = "only with keiro-upgrade, when the build depends on shibuya-kiroku-adapter: keiro 0.25 moves it to the shibuya-core 0.13 cohort (kizashi pilot)"
  }
, { name = "shibuya-pgmq-adapter-upgrade"
  , kind = "migrate"
  , source = "mori://shinzui/shibuya-pgmq-adapter"
  , rule = "only with keiro-upgrade, when the build depends on shibuya-pgmq-adapter: keiro 0.25 moves it to the shibuya-core 0.13 cohort (kizashi pilot)"
  }
, { name = "kiroku-upgrade"
  , kind = "migrate"
  , source = "mori://shinzui/kiroku"
  , rule = "only when keiro-upgrade is not selected (keiro-upgrade entails kiroku's edges) and kiroku is a direct dependency below the version keiro 0.25 needs"
  }
, { name = "migrate-keiro-stack"
  , kind = "run"
  , source = "mori://shinzui/agent-seihou"
  , rule = "deferred to the batches by the operator on 2026-11-17: do not select it for the pilot or the second repository. In a batch run, select it when the project is not yet on pg-migrate, Settei and the six-package vertical structure; set vars to --var=database.policy=disposable"
  }
]
