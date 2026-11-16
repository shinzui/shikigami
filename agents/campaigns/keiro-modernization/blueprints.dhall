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
  , rule = "the build resolves keiro below 0.25; on the first run pass --from with the resolved version"
  }
, { name = "kiroku-upgrade"
  , kind = "migrate"
  , source = "mori://shinzui/kiroku"
  , rule = "the build resolves kiroku directly; keiro-upgrade entails its edges, so select it only when kiroku is a direct dependency"
  }
, { name = "migrate-keiro-stack"
  , kind = "run"
  , source = "mori://shinzui/agent-seihou"
  , rule = "the project is not yet on pg-migrate, Settei and the six-package vertical structure; set vars to --var=database.policy=disposable"
  }
]
