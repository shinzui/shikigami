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
    , dependencies =
      [ "shinzui/kioku"
      , "shinzui/handan"
      , "shinzui/shikumi"
      , "shinzui/baikai"
      , "shinzui/kafka-effectful"
      , "shinzui/keiro"
      , "shinzui/kiroku"
      , "shinzui/shibuya"
      , "shinzui/pgmq-hs"
      , "shinzui/keiki"
      ]
    , okfBundles =
      [ Schema.OkfBundle::{
        , name = "improvement-requests"
        , path = "docs/improvement-requests"
        , profile = Some "docs/improvement-requests/profile.dhall"
        , okfVersion = "0.1"
        , description = Some "Shikigami-owned improvement requests"
        }
      ]
    }
