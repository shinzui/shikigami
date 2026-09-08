let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/b85081a0e935a976202fd7a1227f8b93e2cbeb23/package.dhall
        sha256:1501e5c3e55e78d2a58774e2f8aefda20e32b948fa7caf639473fce90929464b

in  Schema.Project::{
    , project = Schema.ProjectIdentity::{
      , name = "shikigami"
      , namespace = "shinzui"
      , type = Schema.PackageType.Application
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Active
      , description = Some
          "Declared-agent runtime: run a declared behavior when a trigger fires and send the result to sinks, with kioku memory across runs"
      , domains = [ "DeclaredAgents", "ActivityStream", "AgentRuntime" ]
      , owners = [ "shinzui" ]
      }
    , repos = [ Schema.Repo::{ name = "shikigami", github = Some "shinzui/shikigami" } ]
    , packages =
      [ Schema.Package::{
        , name = "shikigami-core"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shikigami-core"
        , description = Some "Shikigami runtime core (loader, scope helper)"
        , dependencies =
          [ Schema.Dependency.WithAugmentation
              { name = "haskell/aeson:aeson"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=2.2"
              }
          , Schema.Dependency.ByName "shinzui/baikai:baikai"
          , Schema.Dependency.ByName "shinzui/baikai:baikai-claude"
          , Schema.Dependency.WithAugmentation
              { name = "nikita-volkov/contravariant-extras:contravariant-extras"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "^>=0.3"
              }
          , Schema.Dependency.ByName "shinzui/danwa:danwa-api"
          , Schema.Dependency.ByName "shinzui/danwa:danwa-client"
          , Schema.Dependency.WithAugmentation
              { name = "dhall-lang/dhall-haskell:dhall"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=1.42"
              }
          , Schema.Dependency.ByName "effectful/effectful:effectful"
          , Schema.Dependency.ByName "effectful/effectful:effectful-core"
          , Schema.Dependency.ByName "shinzui/en:en-biscuit"
          , Schema.Dependency.WithAugmentation
              { name = "ekmett/lens:generic-lens"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=2.2"
              }
          , Schema.Dependency.ByName "shinzui/handan:handan-core"
          , Schema.Dependency.ByName "hasql/hasql:hasql"
          , Schema.Dependency.ByName "hasql/hasql:hasql-pool"
          , Schema.Dependency.ByName "hasql/hasql:hasql-transaction"
          , Schema.Dependency.ByName "iand675/hs-opentelemetry:hs-opentelemetry-api"
          , Schema.Dependency.WithAugmentation
              { name = "iand675/hs-opentelemetry:hs-opentelemetry-exporter-in-memory"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.ByName "iand675/hs-opentelemetry:hs-opentelemetry-propagator-w3c"
          , Schema.Dependency.WithAugmentation
              { name = "iand675/hs-opentelemetry:hs-opentelemetry-sdk"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.ByName "snoyberg/http-client:http-client"
          , Schema.Dependency.WithAugmentation
              { name = "snoyberg/http-client:http-client-tls"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "==0.4.0"
              }
          , Schema.Dependency.ByName "shinzui/keiki:keiki"
          , Schema.Dependency.ByName "shinzui/keiro:keiro"
          , Schema.Dependency.ByName "shinzui/keiro:keiro-core"
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/keiro:keiro-pgmq"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "^>=0.15.0.0"
              }
          , Schema.Dependency.ByName "shinzui/kikan-en:kikan-en-client"
          , Schema.Dependency.ByName "shinzui/kikan-en:kikan-en-contract"
          , Schema.Dependency.ByName "shinzui/kioku:kioku-api"
          , Schema.Dependency.ByName "shinzui/kioku:kioku-core"
          , Schema.Dependency.ByName "shinzui/kiroku:kiroku-store"
          , Schema.Dependency.WithAugmentation
              { name = "ekmett/lens:lens"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=5.2"
              }
          , Schema.Dependency.ByName "MMZK1526/mmzk-typeid:mmzk-typeid"
          , Schema.Dependency.WithAugmentation
              { name = "pcapriotti/optparse-applicative:optparse-applicative"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.19 && <0.20"
              }
          , Schema.Dependency.ByName "shinzui/pgmq-hs:pgmq-hasql"
          , Schema.Dependency.WithAugmentation
              { name = "haskell-servant/servant:servant-client"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.20 && <0.21"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/settei:settei"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "==0.2.0.0"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/settei:settei-env"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "==0.2.0.0"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/settei:settei-optparse-applicative"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "==0.2.0.0"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/settei:settei-yaml"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "==0.2.0.0"
              }
          , Schema.Dependency.ByName "shinzui/shibuya:shibuya-core"
          , Schema.Dependency.ByName "shinzui/shikumi:shikumi"
          , Schema.Dependency.ByName "shinzui/shikumi:shikumi-tools"
          , Schema.Dependency.ByName "shinzui/shomei:shomei-client"
          , Schema.Dependency.ByName "shinzui/shomei:shomei-servant"
          , Schema.Dependency.ByName "composewell/streamly:streamly-core"
          , Schema.Dependency.WithAugmentation
              { name = "UnkindPartition/tasty:tasty"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.WithAugmentation
              { name = "UnkindPartition/tasty:tasty-hunit"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.ByName "haskell-hvr/uuid:uuid"
          , Schema.Dependency.WithAugmentation
              { name = "yesodweb/wai:wai"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.WithAugmentation
              { name = "yesodweb/wai:warp"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          ]
        }
      , Schema.Package::{
        , name = "shikigami-api"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shikigami-api"
        , description = Some "Shikigami public HTTP contract (routes, DTOs, problem details)"
        , dependencies =
          [ Schema.Dependency.WithAugmentation
              { name = "haskell/aeson:aeson"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=2.2"
              }
          , Schema.Dependency.WithAugmentation
              { name = "ekmett/lens:lens"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=5.2"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/openapi-hs:openapi-hs"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=5.0 && <5.1"
              }
          , Schema.Dependency.WithAugmentation
              { name = "haskell-servant/servant:servant"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.20 && <0.21"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/servant-health:servant-health"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.1 && <0.2"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/servant-openapi-hs:servant-openapi-hs"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=5.1 && <5.2"
              }
          , Schema.Dependency.WithAugmentation
              { name = "UnkindPartition/tasty:tasty"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.WithAugmentation
              { name = "UnkindPartition/tasty:tasty-hunit"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          ]
        }
      , Schema.Package::{
        , name = "shikigami-client"
        , type = Schema.PackageType.Client
        , language = Schema.Language.Haskell
        , path = Some "shikigami-client"
        , description = Some "Typed client for the Shikigami HTTP API"
        , dependencies =
          [ Schema.Dependency.WithAugmentation
              { name = "snoyberg/http-client:http-client"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.7"
              }
          , Schema.Dependency.WithAugmentation
              { name = "snoyberg/http-client:http-client-tls"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.3"
              }
          , Schema.Dependency.WithAugmentation
              { name = "pcapriotti/optparse-applicative:optparse-applicative"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.18"
              }
          , Schema.Dependency.WithAugmentation
              { name = "haskell-servant/servant:servant"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.20 && <0.21"
              }
          , Schema.Dependency.WithAugmentation
              { name = "haskell-servant/servant:servant-client"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.20 && <0.21"
              }
          , Schema.Dependency.WithAugmentation
              { name = "haskell-servant/servant:servant-client-core"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.20 && <0.21"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/servant-health:servant-health"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.1 && <0.2"
              }
          , Schema.Dependency.WithAugmentation
              { name = "UnkindPartition/tasty:tasty"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.WithAugmentation
              { name = "UnkindPartition/tasty:tasty-hunit"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          ]
        }
      , Schema.Package::{
        , name = "shikigami-agent"
        , type = Schema.PackageType.Tool
        , language = Schema.Language.Haskell
        , path = Some "shikigami-agent"
        , description = Some "One-off agent runs, without the platform"
        , dependencies =
          [ Schema.Dependency.WithAugmentation
              { name = "haskell/aeson:aeson"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=2.2"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/baikai:baikai"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.ByName "effectful/effectful:effectful"
          , Schema.Dependency.WithAugmentation
              { name = "ekmett/lens:generic-lens"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.ByName "shinzui/keiro:keiro"
          , Schema.Dependency.ByName "shinzui/kioku:kioku-api"
          , Schema.Dependency.ByName "shinzui/kioku:kioku-core"
          , Schema.Dependency.ByName "shinzui/kiroku:kiroku-store"
          , Schema.Dependency.WithAugmentation
              { name = "ekmett/lens:lens"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.WithAugmentation
              { name = "pcapriotti/optparse-applicative:optparse-applicative"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.19 && <0.20"
              }
          , Schema.Dependency.ByName "haskell-hvr/regex-tdfa:regex-tdfa"
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/shikumi:shikumi"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "==0.3.0.3"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/shikumi:shikumi-tools"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "==0.3.0.3"
              }
          , Schema.Dependency.WithAugmentation
              { name = "UnkindPartition/tasty:tasty"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.WithAugmentation
              { name = "UnkindPartition/tasty:tasty-hunit"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          ]
        }
      , Schema.Package::{
        , name = "shikigami-migrations"
        , type = Schema.PackageType.Tool
        , language = Schema.Language.Haskell
        , path = Some "shikigami-migrations"
        , description = Some "Schema migrations for shikigami (composes kioku + shikigami_fired)"
        , dependencies =
          [ Schema.Dependency.WithAugmentation
              { name = "haskell/aeson:aeson"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=2.2 && <2.3"
              }
          , Schema.Dependency.ByName "hasql/hasql:hasql"
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/keiro:keiro-migrations"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "^>=0.15.0.0"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/keiro:keiro-test-support"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = Some "^>=0.15.0.0"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/kioku:kioku-core"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "^>=0.5.0.0"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/kioku:kioku-migrations"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "^>=0.5.0.0 | ^>=0.5.2.0"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/kiroku:kiroku-store"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "^>=0.8.0.0"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/kiroku:kiroku-store-migrations"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "^>=0.4.0.0"
              }
          , Schema.Dependency.WithAugmentation
              { name = "pcapriotti/optparse-applicative:optparse-applicative"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.19 && <0.20"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/pg-migrate:pg-migrate"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "^>=1.1.0.0"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/pg-migrate:pg-migrate-cli"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "^>=1.1.0.0"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/pg-migrate:pg-migrate-embed"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "^>=1.1.0.0"
              }
          , Schema.Dependency.WithAugmentation
              { name = "UnkindPartition/tasty:tasty"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.WithAugmentation
              { name = "UnkindPartition/tasty:tasty-hunit"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          ]
        }
      , Schema.Package::{
        , name = "shikigami-server"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "shikigami-server"
        , description = Some "Shikigami HTTP server and administrative commands"
        , dependencies =
          [ Schema.Dependency.WithAugmentation
              { name = "haskell/aeson:aeson"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=2.2"
              }
          , Schema.Dependency.ByName "shinzui/danwa:danwa-api"
          , Schema.Dependency.ByName "shinzui/danwa:danwa-client"
          , Schema.Dependency.ByName "effectful/effectful:effectful"
          , Schema.Dependency.ByName "hasql/hasql:hasql-pool"
          , Schema.Dependency.ByName "iand675/hs-opentelemetry:hs-opentelemetry-api"
          , Schema.Dependency.WithAugmentation
              { name = "iand675/hs-opentelemetry:hs-opentelemetry-exporter-in-memory"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.ByName "iand675/hs-opentelemetry:hs-opentelemetry-exporter-otlp"
          , Schema.Dependency.ByName "iand675/hs-opentelemetry:hs-opentelemetry-instrumentation-wai"
          , Schema.Dependency.ByName "iand675/hs-opentelemetry:hs-opentelemetry-propagator-w3c"
          , Schema.Dependency.ByName "iand675/hs-opentelemetry:hs-opentelemetry-sdk"
          , Schema.Dependency.WithAugmentation
              { name = "snoyberg/http-client:http-client"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.ByName "haskell-works/hw-kafka-client:hw-kafka-client"
          , Schema.Dependency.ByName "shinzui/kafka-effectful:kafka-effectful"
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/keiro:keiro"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "==0.15.0.0"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/keiro:keiro-ops"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "==0.15.0.0"
              }
          , Schema.Dependency.ByName "shinzui/kioku:kioku-api"
          , Schema.Dependency.ByName "shinzui/kioku:kioku-core"
          , Schema.Dependency.ByName "shinzui/kiroku:kiroku-store"
          , Schema.Dependency.WithAugmentation
              { name = "ekmett/lens:lens"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.ByName "MMZK1526/mmzk-typeid:mmzk-typeid"
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/openapi-hs:openapi-hs"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.WithAugmentation
              { name = "pcapriotti/optparse-applicative:optparse-applicative"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.18"
              }
          , Schema.Dependency.WithAugmentation
              { name = "haskell-servant/servant:servant"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.20 && <0.21"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/servant-health:servant-health"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.1 && <0.2"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/servant-health:servant-health:testkit"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.WithAugmentation
              { name = "haskell-servant/servant:servant-server"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.20 && <0.21"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/settei:settei"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "==0.2.0.0"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/settei:settei-env"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/settei:settei-optparse-applicative"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "==0.2.0.0"
              }
          , Schema.Dependency.WithAugmentation
              { name = "UnkindPartition/tasty:tasty"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.WithAugmentation
              { name = "UnkindPartition/tasty:tasty-hunit"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.WithAugmentation
              { name = "haskell-hvr/uuid:uuid"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=1.3 && <1.4"
              }
          , Schema.Dependency.ByName "yesodweb/wai:wai"
          , Schema.Dependency.ByName "yesodweb/wai:warp"
          ]
        }
      , Schema.Package::{
        , name = "shikigami-workers"
        , type = Schema.PackageType.Worker
        , language = Schema.Language.Haskell
        , path = Some "shikigami-workers"
        , description = Some "Shikigami supervised background loops"
        , dependencies =
          [ Schema.Dependency.WithAugmentation
              { name = "haskell/aeson:aeson"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=2.2"
              }
          , Schema.Dependency.ByName "shinzui/baikai:baikai-trace-otel"
          , Schema.Dependency.ByName "effectful/effectful:effectful"
          , Schema.Dependency.ByName "ekmett/lens:generic-lens"
          , Schema.Dependency.ByName "hasql/hasql:hasql"
          , Schema.Dependency.ByName "hasql/hasql:hasql-pool"
          , Schema.Dependency.ByName "hasql/hasql:hasql-transaction"
          , Schema.Dependency.ByName "iand675/hs-opentelemetry:hs-opentelemetry-api"
          , Schema.Dependency.WithAugmentation
              { name = "iand675/hs-opentelemetry:hs-opentelemetry-exporter-in-memory"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.ByName "iand675/hs-opentelemetry:hs-opentelemetry-exporter-otlp"
          , Schema.Dependency.ByName "iand675/hs-opentelemetry:hs-opentelemetry-sdk"
          , Schema.Dependency.ByName "snoyberg/http-client:http-client"
          , Schema.Dependency.ByName "snoyberg/http-client:http-client-tls"
          , Schema.Dependency.ByName "haskell-works/hw-kafka-client:hw-kafka-client"
          , Schema.Dependency.ByName "shinzui/kafka-effectful:kafka-effectful"
          , Schema.Dependency.ByName "shinzui/keiro:keiro"
          , Schema.Dependency.ByName "shinzui/keiro:keiro-pgmq"
          , Schema.Dependency.ByName "shinzui/kikan-en:kikan-en-client"
          , Schema.Dependency.ByName "shinzui/kioku:kioku-api"
          , Schema.Dependency.ByName "shinzui/kioku:kioku-core"
          , Schema.Dependency.ByName "shinzui/kiroku:kiroku-store"
          , Schema.Dependency.WithAugmentation
              { name = "ekmett/lens:lens"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=5.2"
              }
          , Schema.Dependency.WithAugmentation
              { name = "pcapriotti/optparse-applicative:optparse-applicative"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.19 && <0.20"
              }
          , Schema.Dependency.ByName "shinzui/pgmq-hs:pgmq-hasql"
          , Schema.Dependency.WithAugmentation
              { name = "haskell-servant/servant:servant"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.20 && <0.21"
              }
          , Schema.Dependency.WithAugmentation
              { name = "haskell-servant/servant:servant-client"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.20 && <0.21"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/servant-health:servant-health"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.1 && <0.2"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/servant-health:servant-health:testkit"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.WithAugmentation
              { name = "haskell-servant/servant:servant-server"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.20 && <0.21"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/settei:settei"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "==0.2.0.0"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/settei:settei-env"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/settei:settei-optparse-applicative"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "==0.2.0.0"
              }
          , Schema.Dependency.ByName "shinzui/shibuya:shibuya-core"
          , Schema.Dependency.ByName "shinzui/shibuya-kafka-adapter:shibuya-kafka-adapter"
          , Schema.Dependency.WithAugmentation
              { name = "UnkindPartition/tasty:tasty"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.WithAugmentation
              { name = "UnkindPartition/tasty:tasty-hunit"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.ByName "haskell-hvr/uuid:uuid"
          , Schema.Dependency.ByName "yesodweb/wai:wai"
          , Schema.Dependency.ByName "yesodweb/wai:warp"
          ]
        }
      ]
    , dependencies =
      [ "MMZK1526/mmzk-typeid:mmzk-typeid"
      , "UnkindPartition/tasty:tasty"
      , "UnkindPartition/tasty:tasty-hunit"
      , "composewell/streamly:streamly-core"
      , "dhall-lang/dhall-haskell:dhall"
      , "effectful/effectful:effectful"
      , "effectful/effectful:effectful-core"
      , "ekmett/lens:generic-lens"
      , "ekmett/lens:lens"
      , "haskell-hvr/regex-tdfa:regex-tdfa"
      , "haskell-hvr/uuid:uuid"
      , "haskell-servant/servant:servant"
      , "haskell-servant/servant:servant-client"
      , "haskell-servant/servant:servant-client-core"
      , "haskell-servant/servant:servant-server"
      , "haskell/aeson:aeson"
      , "hasql/hasql:hasql"
      , "hasql/hasql:hasql-pool"
      , "hasql/hasql:hasql-transaction"
      , "iand675/hs-opentelemetry:hs-opentelemetry-api"
      , "iand675/hs-opentelemetry:hs-opentelemetry-exporter-in-memory"
      , "iand675/hs-opentelemetry:hs-opentelemetry-exporter-otlp"
      , "iand675/hs-opentelemetry:hs-opentelemetry-instrumentation-wai"
      , "iand675/hs-opentelemetry:hs-opentelemetry-propagator-w3c"
      , "iand675/hs-opentelemetry:hs-opentelemetry-sdk"
      , "nikita-volkov/contravariant-extras:contravariant-extras"
      , "pcapriotti/optparse-applicative:optparse-applicative"
      , "shinzui/baikai:baikai"
      , "shinzui/baikai:baikai-claude"
      , "shinzui/baikai:baikai-trace-otel"
      , "shinzui/biscuit-haskell:biscuit-haskell"
      , "shinzui/danwa:danwa-api"
      , "shinzui/danwa:danwa-client"
      , "shinzui/en:en-biscuit"
      , "shinzui/handan:handan-core"
      , "haskell-works/hw-kafka-client:hw-kafka-client"
      , "shinzui/kafka-effectful:kafka-effectful"
      , "shinzui/keiki:keiki"
      , "shinzui/keiro:keiro"
      , "shinzui/keiro:keiro-core"
      , "shinzui/keiro:keiro-dsl"
      , "shinzui/keiro:keiro-migrations"
      , "shinzui/keiro:keiro-ops"
      , "shinzui/keiro:keiro-pgmq"
      , "shinzui/keiro:keiro-test-support"
      , "shinzui/kikan-en:kikan-en-client"
      , "shinzui/kikan-en:kikan-en-contract"
      , "shinzui/kioku:kioku-api"
      , "shinzui/kioku:kioku-core"
      , "shinzui/kioku:kioku-migrations"
      , "shinzui/kiroku:kiroku-store"
      , "shinzui/kiroku:kiroku-store-migrations"
      , "shinzui/openapi-hs:openapi-hs"
      , "shinzui/pg-migrate:pg-migrate"
      , "shinzui/pg-migrate:pg-migrate-cli"
      , "shinzui/pg-migrate:pg-migrate-embed"
      , "shinzui/pgmq-hs:pgmq-hasql"
      , "shinzui/servant-health:servant-health"
      , "shinzui/servant-health:servant-health:testkit"
      , "shinzui/servant-openapi-hs:servant-openapi-hs"
      , "shinzui/settei:settei"
      , "shinzui/settei:settei-env"
      , "shinzui/settei:settei-optparse-applicative"
      , "shinzui/settei:settei-yaml"
      , "shinzui/shibuya-kafka-adapter:shibuya-kafka-adapter"
      , "shinzui/shibuya:shibuya-core"
      , "shinzui/shikumi:shikumi"
      , "shinzui/shikumi:shikumi-tools"
      , "shinzui/shomei:shomei-client"
      , "shinzui/shomei:shomei-servant"
      , "snoyberg/http-client:http-client"
      , "snoyberg/http-client:http-client-tls"
      , "yesodweb/wai:wai"
      , "yesodweb/wai:warp"
      ]
    , dependencyRefs =
      [ Schema.MoriRef::{
        , namespace = "MMZK1526"
        , name = "mmzk-typeid"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "mmzk-typeid"
        }
      , Schema.MoriRef::{
        , namespace = "UnkindPartition"
        , name = "tasty"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "tasty"
        }
      , Schema.MoriRef::{
        , namespace = "UnkindPartition"
        , name = "tasty"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "tasty-hunit"
        }
      , Schema.MoriRef::{
        , namespace = "composewell"
        , name = "streamly"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "streamly-core"
        }
      , Schema.MoriRef::{
        , namespace = "dhall-lang"
        , name = "dhall-haskell"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "dhall"
        }
      , Schema.MoriRef::{
        , namespace = "effectful"
        , name = "effectful"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "effectful"
        }
      , Schema.MoriRef::{
        , namespace = "effectful"
        , name = "effectful"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "effectful-core"
        }
      , Schema.MoriRef::{
        , namespace = "ekmett"
        , name = "lens"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "generic-lens"
        }
      , Schema.MoriRef::{
        , namespace = "ekmett"
        , name = "lens"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "lens"
        }
      , Schema.MoriRef::{
        , namespace = "haskell-hvr"
        , name = "regex-tdfa"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "regex-tdfa"
        }
      , Schema.MoriRef::{
        , namespace = "haskell-hvr"
        , name = "uuid"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "uuid"
        }
      , Schema.MoriRef::{
        , namespace = "haskell-servant"
        , name = "servant"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "servant"
        }
      , Schema.MoriRef::{
        , namespace = "haskell-servant"
        , name = "servant"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "servant-client"
        }
      , Schema.MoriRef::{
        , namespace = "haskell-servant"
        , name = "servant"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "servant-client-core"
        }
      , Schema.MoriRef::{
        , namespace = "haskell-servant"
        , name = "servant"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "servant-server"
        }
      , Schema.MoriRef::{
        , namespace = "haskell"
        , name = "aeson"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "aeson"
        }
      , Schema.MoriRef::{
        , namespace = "hasql"
        , name = "hasql"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hasql"
        }
      , Schema.MoriRef::{
        , namespace = "hasql"
        , name = "hasql"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hasql-pool"
        }
      , Schema.MoriRef::{
        , namespace = "hasql"
        , name = "hasql"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hasql-transaction"
        }
      , Schema.MoriRef::{
        , namespace = "iand675"
        , name = "hs-opentelemetry"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hs-opentelemetry-api"
        }
      , Schema.MoriRef::{
        , namespace = "iand675"
        , name = "hs-opentelemetry"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hs-opentelemetry-exporter-in-memory"
        }
      , Schema.MoriRef::{
        , namespace = "iand675"
        , name = "hs-opentelemetry"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hs-opentelemetry-exporter-otlp"
        }
      , Schema.MoriRef::{
        , namespace = "iand675"
        , name = "hs-opentelemetry"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hs-opentelemetry-instrumentation-wai"
        }
      , Schema.MoriRef::{
        , namespace = "iand675"
        , name = "hs-opentelemetry"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hs-opentelemetry-propagator-w3c"
        }
      , Schema.MoriRef::{
        , namespace = "iand675"
        , name = "hs-opentelemetry"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hs-opentelemetry-sdk"
        }
      , Schema.MoriRef::{
        , namespace = "nikita-volkov"
        , name = "contravariant-extras"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "contravariant-extras"
        }
      , Schema.MoriRef::{
        , namespace = "pcapriotti"
        , name = "optparse-applicative"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "optparse-applicative"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "baikai"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "baikai"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "baikai"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "baikai-claude"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "baikai"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "baikai-trace-otel"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "biscuit-haskell"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "biscuit-haskell"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "danwa"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "danwa-api"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "danwa"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "danwa-client"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "en"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "en-biscuit"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "handan"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "handan-core"
        }
      , Schema.MoriRef::{
        , namespace = "haskell-works"
        , name = "hw-kafka-client"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hw-kafka-client"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "kafka-effectful"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "kafka-effectful"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "keiki"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "keiki"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "keiro"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "keiro"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "keiro"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "keiro-core"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "keiro"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "keiro-dsl"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "keiro"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "keiro-migrations"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "keiro"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "keiro-ops"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "keiro"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "keiro-pgmq"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "keiro"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "keiro-test-support"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "kikan-en"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "kikan-en-client"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "kikan-en"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "kikan-en-contract"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "kioku"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "kioku-api"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "kioku"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "kioku-core"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "kioku"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "kioku-migrations"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "kiroku"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "kiroku-store"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "kiroku"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "kiroku-store-migrations"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "openapi-hs"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "openapi-hs"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "pg-migrate"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "pg-migrate"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "pg-migrate"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "pg-migrate-cli"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "pg-migrate"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "pg-migrate-embed"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "pgmq-hs"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "pgmq-hasql"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "servant-health"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "servant-health"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "servant-health"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "servant-health:testkit"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "servant-openapi-hs"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "servant-openapi-hs"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "settei"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "settei"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "settei"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "settei-env"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "settei"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "settei-optparse-applicative"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "settei"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "settei-yaml"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "shibuya-kafka-adapter"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "shibuya-kafka-adapter"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "shibuya"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "shibuya-core"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "shikumi"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "shikumi"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "shikumi"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "shikumi-tools"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "shomei"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "shomei-client"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "shomei"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "shomei-servant"
        }
      , Schema.MoriRef::{
        , namespace = "snoyberg"
        , name = "http-client"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "http-client"
        }
      , Schema.MoriRef::{
        , namespace = "snoyberg"
        , name = "http-client"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "http-client-tls"
        }
      , Schema.MoriRef::{
        , namespace = "yesodweb"
        , name = "wai"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "wai"
        }
      , Schema.MoriRef::{
        , namespace = "yesodweb"
        , name = "wai"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "warp"
        }
      ]
    , okfBundles =
      [ Schema.OkfBundle::{
        , name = "user"
        , path = "docs/user"
        , profile = Some "docs/user/profile.dhall"
        , okfVersion = "0.2"
        , description = Some "Shikigami user documentation organized by reader intent"
        }
      , Schema.OkfBundle::{
        , name = "improvement-requests"
        , path = "docs/improvement-requests"
        , profile = Some "docs/improvement-requests/profile.dhall"
        , okfVersion = "0.2"
        , description = Some "Shikigami-owned improvement requests"
        }
      , Schema.OkfBundle::{
        , name = "reviews"
        , path = "docs/reviews"
        , profile = Some "docs/reviews/profile.dhall"
        , okfVersion = "0.2"
        , description = Some
            "Commit-pinned records of Shikigami artifacts having been reviewed"
        }
      ]
    }
