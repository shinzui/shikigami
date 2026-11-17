-- | The development stubs of the Kikan services, as admin verbs of the
-- distribution's @kikan-shikigami@ command (plan 135, M3).
--
-- @stub-kawa@ and @stub-kanmon@ stand in for Kawa's ingest doorway and
-- Kanmon's channel-action route in a local end-to-end run. They are fixtures
-- for Kikan services, so the stock admin command no longer offers them. Each
-- requires the bearer token the binding's outputs send, read from the
-- binding's secret setting.
module Kikan.Shikigami.Stub
  ( stubsPack,
  )
where

import Data.Set qualified as Set
import Data.Text qualified as Text
import Kikan.Shikigami.Stub.Kanmon (StubKanmonOptions (..), runStubKanmon)
import Kikan.Shikigami.Stub.Kawa (StubKawaOptions (..), runStubKawa)
import Options.Applicative
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Flow.Sdk (FlowPack (..), noTriggerHooks, parseFlowPackName)
import Shikigami.Pack.Sdk (AdminContext (..), AdminVerb (..), packSettingSecret)
import Shikigami.Sink.Auth (packSecretToken)

-- | A pack holding only the stub verbs; composed by the admin executable.
stubsPack :: FlowPack
stubsPack =
  FlowPack
    { name = either (error . show) id (parseFlowPackName "kikan-stubs"),
      flows = [],
      decisionPrograms = [],
      retainedCodecs = [],
      tasks = [],
      settings = [],
      triggers = noTriggerHooks,
      adminVerbs = [stubKawa, stubKanmon],
      gauges = [],
      authorities = [],
      outputs = [],
      approvalChannels = []
    }

-- | @stub-kawa --port <n> [--republish-topic <t>] [--broker <host:port>]@.
stubKawa :: AdminVerb
stubKawa =
  AdminVerb
    { name = "stub-kawa",
      parser =
        info
          (verb <**> helper)
          (progDesc "Run the kawa ingest doorway stub, optionally republishing to a topic")
    }
  where
    verb =
      ( \port republishTopic broker context ->
          runStubKawa
            StubKawaOptions
              { port,
                republishTopic = Text.pack <$> republishTopic,
                broker = Just (Text.pack broker),
                requireToken = packSecretToken <$> packSettingSecret "credentials.sinks.kawa.token" context.settings
              }
      )
        <$> option auto (long "port" <> metavar "PORT" <> help "Port to listen on")
        <*> optional (strOption (long "republish-topic" <> metavar "TOPIC" <> help "Re-publish accepted envelopes onto this Kafka topic"))
        <*> strOption (long "broker" <> metavar "HOST:PORT" <> value "127.0.0.1:9092" <> showDefault <> help "Kafka broker the republisher writes to")

-- | @stub-kanmon --port <n> [--allow-conversation <key>]...@.
stubKanmon :: AdminVerb
stubKanmon =
  AdminVerb
    { name = "stub-kanmon",
      parser =
        info
          (verb <**> helper)
          (progDesc "Run the authenticated Kanmon channel-egress stub")
    }
  where
    verb =
      ( \port conversations context ->
          runStubKanmon
            StubKanmonOptions
              { port,
                requireToken = packSecretToken <$> packSettingSecret "credentials.sinks.kanmon.token" context.settings,
                allowedConversations = Set.fromList (declarationCoordinate . Text.pack <$> if null conversations then ["conv_55012"] else conversations)
              }
      )
        <$> option auto (long "port" <> metavar "PORT" <> help "Port to listen on")
        <*> many (strOption (long "allow-conversation" <> metavar "KEY" <> help "Conversation key the proof route may target (repeatable; default conv_55012)"))
