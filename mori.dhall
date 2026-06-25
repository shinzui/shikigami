let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/026ae74331e5c516542af1dd96f041c658ed4621/package.dhall
        sha256:18258ef583580a897f4af3e7c86db0342afb42fb40efc535b217ba1089230141

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
    }
