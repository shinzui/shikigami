-- | The single process-level configuration declaration.
--
-- Every Shikigami executable — the HTTP server, each worker role, the
-- administrative commands, the migration runner — resolves its settings from the
-- one declaration in this module, rather than reading the environment where it
-- happens to need a value. Nothing else in this repository may call @getEnv@ or
-- @lookupEnv@; the only exception is the OpenTelemetry SDK, which owns the
-- standard @OTEL_*@ variables and is documented as such at its call site in
-- @shikigami-workers\/src\/Shikigami\/Telemetry.hs@.
--
-- \"Settei\" is the configuration library this module is built on. Three of its
-- ideas are worth naming before you read further, because the rest of the module
-- assumes them.
--
-- A __setting__ is one stable hierarchical key (for example
-- @sinks.danwa.base_url@), a human description, a decoder that turns a raw
-- source value into a typed one, and a sensitivity: public values may be printed
-- in reports, secret values are redacted everywhere. 'Settei.Setting.Setting'
-- values are declared once, below, and nowhere else.
--
-- A __declaration__ ('Settei.Config.Config') is an applicative description of the
-- whole typed result: 'appConfig' says which settings exist, which are required,
-- which have defaults, and how they assemble into 'AppConfig'. Because it is a
-- description rather than an action, @--describe-config@ can print the complete
-- accepted surface without opening a file, a socket, or a database connection.
--
-- A __source__ ('Settei.Source.Source') is one place candidate values come from:
-- a YAML file, the process environment, a command-line option. Resolution is
-- positional — later sources win — and the resolution report keeps every
-- shadowed candidate with its provenance, which is what @--explain-config@
-- prints.
--
-- This module is deliberately pure: it declares, and it does not load. Loading,
-- source ordering, diagnostics, and exit codes belong to
-- "Shikigami.App.Config.Load".
--
-- Two rules bind everything added here, now and later. Secrets are credential
-- references ('CredentialRef') or redacted secret types ('SecretText'), and
-- never gain a 'Show', JSON, or logging rendering that would print their
-- plaintext. And a setting is declared here only when something in the tree
-- actually reads it: an accepted key that no code consults is a lie told by
-- @--describe-config@.
module Shikigami.App.Config
  ( -- * The resolved configuration
    AppConfig (..),

    -- * Value types
    SecretText,
    revealSecretText,
    CredentialRef (..),
    Port,
    mkPort,
    portNumber,

    -- * Which model runs a Skill behavior
    ProviderSelection (..),
    anthropicModels,
    lookupAnthropicModel,

    -- * The declaration
    appConfig,
    appConfigSchema,
    defaultAppConfig,

    -- * Environment bindings
    environmentBindings,

    -- * Which binary needs what
    Role (..),
    roleBinary,
    roleRequiredKeys,
    missingRequirements,

    -- * Stable keys
    databaseConnectionStringKey,
    agentsDirectoryKey,
    kafkaBrokerKey,
    kafkaActivityTopicKey,
    kafkaEventsTopicKey,
    kafkaStreamGroupKey,
    kafkaEventsGroupKey,
    kafkaIncludeAgentActorsKey,
    httpHostKey,
    httpPortKey,
    behaviorProviderKey,
    behaviorModelKey,
    anthropicApiKeyKey,
    sinksKawaBaseUrlKey,
    sinksKawaSourceSegmentKey,
    sinksKizashiBaseUrlKey,
    sinksKizashiDefaultRecipientKey,
    sinksDanwaBaseUrlKey,
    sinksDanwaAgentParticipantKey,
    declaredKeys,
  )
where

import Baikai.Api (Api (AnthropicMessages))
import Baikai.Model (Model, api, modelId, provider)
import Baikai.Models.Generated (allModels, anthropic_claude_sonnet_4_6)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Settei
import Settei.Env

-- ── Value types ─────────────────────────────────────────────────────────────

-- | A resolved secret, kept away from every rendering that could print it.
--
-- The constructor is private and there is deliberately no 'Show', 'Read', or
-- JSON instance: the only way back to plaintext is 'revealSecretText', which is
-- greppable. Settei already redacts secret settings in schema output, resolution
-- reports, and decode failures; this type extends the same guarantee to whatever
-- the application does with the value afterwards.
newtype SecretText = SecretText Text
  deriving stock (Generic, Eq)

-- | Lower a secret to plaintext at the exact boundary that needs it.
--
-- Call this only where a library demands the raw string — a database connection
-- string handed to the store, an @Authorization@ header handed to an HTTP
-- client — and never to log, print, or serialize the result. Every call site is
-- meant to be reviewable by grepping for this function's name.
revealSecretText :: SecretText -> Text
revealSecretText (SecretText value) = value

-- | The stable name of a credential, which is not itself a credential.
--
-- Agent manifests and other declarations may name a credential (for example
-- @credentials.sinks.danwa.token@) so that the declaration stays checkable and
-- shareable while the secret value is resolved at composition time into a
-- 'SecretText'. Because a reference reveals nothing, it keeps 'Show'.
newtype CredentialRef = CredentialRef Text
  deriving stock (Generic, Eq, Ord, Show)

-- | A TCP port, checked at decode time rather than at bind time.
--
-- @0@ and anything above @65535@ are rejected during resolution, so
-- @--check-config@ catches a bad port without opening a listener.
newtype Port = Port Int
  deriving stock (Generic, Eq, Ord)

-- | Build a port, rejecting anything outside 1–65535.
mkPort :: Int -> Either Text Port
mkPort value
  | value >= 1 && value <= 65535 = Right (Port value)
  | otherwise = Left portExpectation

-- | The port as the plain number a listener wants.
portNumber :: Port -> Int
portNumber (Port value) = value

portExpectation :: Text
portExpectation = "a TCP port between 1 and 65535"

-- | Which model the @Skill@ behavior arm dispatches with, and what it
-- authenticates as.
--
-- The two branches carry different things, which is exactly why this is a sum
-- rather than three loose fields. A stub run needs nothing: it answers from a
-- fixed string and never opens a socket. A real run cannot proceed without both
-- a model and a credential, and a configuration that supplies one without the
-- other is a misconfiguration an operator wants to hear about at startup rather
-- than on the first job. Making the pair inseparable in the type means the
-- declaration below is the only place that check has to live, and
-- @--check-config@ performs it.
--
-- There is deliberately no 'Show', 'Read', or JSON instance: 'UseAnthropic'
-- holds a 'SecretText'. Use
-- 'Shikigami.Behavior.Provider.describeProviderSelection' to render it.
data ProviderSelection
  = -- | The deterministic, key-free stub. The default, and what every test runs.
    UseStub
  | -- | A real Anthropic Messages model and the credential to call it with.
    UseAnthropic !Model !SecretText
  deriving stock (Generic, Eq)

-- | Which provider was asked for, before the branch's settings are resolved.
--
-- Private: it exists only as the scrutinee of the conditional declaration, and
-- the resolved answer callers care about is 'ProviderSelection'.
data ProviderChoice = ChooseStub | ChooseAnthropic
  deriving stock (Generic, Eq, Show)

renderProviderChoice :: ProviderChoice -> Text
renderProviderChoice = \case
  ChooseStub -> "stub"
  ChooseAnthropic -> "anthropic"

-- | Every Anthropic Messages model in baikai's generated catalog.
--
-- The catalog is the only source of truth for which model ids exist, what they
-- cost, and which handler answers for them, so 'behavior.model' decodes against
-- it rather than against a list transcribed here. That makes a typo'd model id
-- an exit-4 configuration failure naming the accepted ids, instead of a request
-- rejected by Anthropic on the first job.
--
-- The @provider@ test excludes catalog entries that reach a Claude model through
-- somebody else's gateway; those need that gateway's credential, not this one.
anthropicModels :: [Model]
anthropicModels =
  [ model
  | model <- allModels,
    api model == AnthropicMessages,
    provider model == "anthropic"
  ]

-- | Find a catalog model by its upstream id, e.g. @claude-haiku-4-5@.
lookupAnthropicModel :: Text -> Maybe Model
lookupAnthropicModel wanted = lookup wanted [(modelId model, model) | model <- anthropicModels]

-- ── The resolved configuration ──────────────────────────────────────────────

-- | Everything any Shikigami process is configured with.
--
-- One record for every binary, rather than one per binary, because a single
-- declaration is what lets one configuration file serve every role, lets
-- @--describe-config@ mean the same thing everywhere, and gives later plans one
-- place to extend. Which fields a given binary actually requires is expressed by
-- 'Role' and 'missingRequirements' instead of by a separate declaration.
--
-- The record is flat, and each field is named for the key it resolves — so
-- @kafka.broker@ is 'kafkaBroker'. Grouping the fields into nested @KafkaConfig@
-- and @SinksConfig@ records would put three @baseUrl@ fields in one module, and
-- an ambiguous field selector cannot be used as a plain function. Nothing in the
-- tree wants to pass \"just the sink settings\" around — the sink clients take
-- their own types from "Shikigami.Sink" — so the grouping bought nothing.
--
-- There is no 'Show' instance: 'databaseUrl' is a secret.
data AppConfig = AppConfig
  { -- | PostgreSQL connection string. Optional in the declaration because
    -- @shikigami-run-behavior@ and most administrative commands never open a
    -- database; the roles that do require it are listed by 'roleRequiredKeys'.
    databaseUrl :: !(Maybe SecretText),
    -- | Directory holding the @.dhall@ agent manifests.
    agentsDirectory :: !FilePath,
    -- | Kafka bootstrap broker.
    kafkaBroker :: !Text,
    -- | Topic carrying @activity.v1@ envelopes.
    kafkaActivityTopic :: !Text,
    -- | Topic carrying public integration events.
    kafkaEventsTopic :: !Text,
    -- | Consumer group of the activity-stream consumer.
    kafkaStreamGroup :: !Text,
    -- | Consumer group of the integration-event consumer.
    kafkaEventsGroup :: !Text,
    -- | Whether the activity-stream consumer matches agent-produced activities.
    -- Off by default: leaving it off is the feedback guard that stops an agent's
    -- own output from triggering it again.
    kafkaIncludeAgentActors :: !Bool,
    -- | Interface the public HTTP API binds.
    httpHost :: !Text,
    -- | Port the public HTTP API binds.
    httpPort :: !Port,
    -- | Base URL of the kawa ingest doorway.
    kawaBaseUrl :: !Text,
    -- | Source segment kawa attributes ingested activity to.
    kawaSourceSegment :: !Text,
    -- | Base URL of the kizashi signal service.
    kizashiBaseUrl :: !Text,
    -- | Recipient used when a declared signal names none.
    kizashiDefaultRecipient :: !Text,
    -- | Base URL of the danwa conversation server.
    danwaBaseUrl :: !Text,
    -- | danwa participant id Shikigami authors messages as.
    danwaAgentParticipant :: !Text,
    -- | Which model the @Skill@ behavior arm dispatches with.
    --
    -- The one field that is not named for a single key, because it is not
    -- resolved from one: @behavior.provider@ chooses the branch, and the
    -- Anthropic branch additionally resolves @behavior.model@ and
    -- @credentials.providers.anthropic.api_key@. Keeping them one field is what
    -- makes \"a real provider without a credential\" unrepresentable rather
    -- than something every consumer has to re-check.
    behaviorProvider :: !ProviderSelection
  }
  deriving stock (Generic, Eq)

-- ── The declaration ─────────────────────────────────────────────────────────

-- | The complete accepted configuration surface.
--
-- Everything except 'databaseUrl' has a declared default, so a process starts
-- with no configuration at all and behaves the way the development shell
-- expects. Defaults are declared through Settei rather than baked into a
-- built-in source so that @--explain-config@ can say which rule supplied a value
-- and why.
appConfig :: Config AppConfig
appConfig =
  AppConfig
    <$> optional databaseConnectionStringSetting
    <*> withDefault agentsDirectorySetting (constant "agents-directory" "Manifests live in ./agents relative to the working directory" "agents")
    <*> withDefault kafkaBrokerSetting (constant "kafka-broker" "Use the development shell's local broker" "127.0.0.1:9092")
    <*> withDefault kafkaActivityTopicSetting (constant "activity-topic" "The canonical activity stream topic" "activity.v1")
    <*> withDefault kafkaEventsTopicSetting (constant "events-topic" "danwa's addressed-message integration event" "danwa.message-addressed.v1")
    <*> withDefault kafkaStreamGroupSetting (constant "stream-group" "One consumer group per stream role" "shikigami-stream")
    <*> withDefault kafkaEventsGroupSetting (constant "events-group" "One consumer group per stream role" "shikigami-events")
    <*> withDefault kafkaIncludeAgentActorsSetting (constant "feedback-guard" "Ignore agent-produced activities so an agent cannot trigger itself" False)
    <*> withDefault httpHostSetting (constant "loopback" "Keep a development server off the network" "127.0.0.1")
    <*> withDefault httpPortSetting (constant "http-port" "The conventional Shikigami API port" (Port 8080))
    <*> withDefault sinksKawaBaseUrlSetting (constant "local-kawa" "The local kawa (or stub-kawa) doorway" "http://localhost:8088")
    <*> withDefault sinksKawaSourceSegmentSetting (constant "kawa-source" "This repository's ingest source segment" "shinzui/shikigami")
    <*> withDefault sinksKizashiBaseUrlSetting (constant "local-kizashi" "The local kizashi service" "http://localhost:8089")
    <*> withDefault sinksKizashiDefaultRecipientSetting (constant "kizashi-recipient" "Recipient used when a signal declares none" "recipient:default")
    <*> withDefault sinksDanwaBaseUrlSetting (constant "local-danwa" "The local danwa server" "http://localhost:8080")
    <*> withDefault sinksDanwaAgentParticipantSetting (constant "danwa-agent" "Participant id Shikigami authors messages as" "part_shikigami")
    <*> behaviorProviderConfig

-- | Which provider runs a Skill behavior, and what the real branch needs.
--
-- This is the declaration's one conditional path. @behavior.model@ and
-- @credentials.providers.anthropic.api_key@ are consulted only when
-- @behavior.provider@ selected @anthropic@, so a stub deployment is never asked
-- for a credential it has no use for, and an Anthropic deployment cannot start
-- without one: the key is 'required' inside the branch, which makes a missing
-- credential an ordinary resolution failure with the reserved exit code, named
-- by key, and caught by @--check-config@ before the worker opens anything.
--
-- Expressed with 'whenEq' rather than a post-resolution check so that the
-- requirement appears in @--describe-config@ as a condition on the schema, and
-- so it cannot be forgotten by a caller that resolves configuration and then
-- builds a behavior environment its own way.
behaviorProviderConfig :: Config ProviderSelection
behaviorProviderConfig =
  maybe UseStub (uncurry UseAnthropic)
    <$> whenEq
      (withDefault behaviorProviderSetting (constant "stub-provider" "No model is called until an operator asks for one" ChooseStub))
      ChooseAnthropic
      ( (,)
          <$> withDefault behaviorModelSetting (constant "default-model" "The current general-purpose Claude model" anthropic_claude_sonnet_4_6)
          <*> required anthropicApiKeySetting
      )

-- | The static schema, for @--describe-config@ and for tests.
appConfigSchema :: Schema
appConfigSchema = describe appConfig

-- | What 'appConfig' resolves to when no source supplies anything.
--
-- Computed by resolving the declaration against an empty source list rather than
-- written out by hand, so it cannot drift from the declared defaults. Tests and
-- in-process fixtures that need an 'AppConfig' without running a command line
-- use this; it is the same value a process gets with no configuration file, no
-- bound environment variable, and no flag.
--
-- Resolution cannot fail here: every setting except 'databaseUrl' has a declared
-- default, and 'databaseUrl' is optional. A failure would mean the declaration
-- itself is broken, which is a programming error rather than an operator error.
defaultAppConfig :: AppConfig
defaultAppConfig =
  case answer (resolve defaultResolveOptions [] appConfig) of
    Right value -> value
    Left problems -> error (Text.unpack ("the configuration declaration has no defaults: " <> renderErrorsText problems))

-- | A named constant default. Every default carries a rule name and an
-- explanation so @--explain-config@ says where an unset value came from.
constant :: Text -> Text -> a -> Default a
constant rule explanation = constantDefault (RuleName rule) explanation

-- ── Settings ────────────────────────────────────────────────────────────────
--
-- Every public setting carries a renderer, even the textual ones where the
-- renderer is 'id'. Without it @--explain-config@ prints @\<derived\>@ for a
-- value that came from a default rule, which tells an operator the rule fired
-- but not what it chose. A secret setting deliberately has no renderer: its
-- value is redacted whatever its source.

databaseConnectionStringSetting :: Setting SecretText
databaseConnectionStringSetting =
  secretSetting
    databaseConnectionStringKey
    "PostgreSQL connection string (libpq URI or key/value form)"
    (SecretText <$> textDecoder)

agentsDirectorySetting :: Setting FilePath
agentsDirectorySetting =
  publicSettingWithRenderer
    agentsDirectoryKey
    "Directory containing agent manifests (.dhall)"
    (Text.unpack <$> textDecoder)
    Text.pack

kafkaBrokerSetting :: Setting Text
kafkaBrokerSetting = publicSettingWithRenderer kafkaBrokerKey "Kafka bootstrap broker, HOST:PORT" textDecoder id

kafkaActivityTopicSetting :: Setting Text
kafkaActivityTopicSetting = publicSettingWithRenderer kafkaActivityTopicKey "Topic carrying activity.v1 envelopes" textDecoder id

kafkaEventsTopicSetting :: Setting Text
kafkaEventsTopicSetting = publicSettingWithRenderer kafkaEventsTopicKey "Topic carrying public integration events" textDecoder id

kafkaStreamGroupSetting :: Setting Text
kafkaStreamGroupSetting = publicSettingWithRenderer kafkaStreamGroupKey "Consumer group id for the activity stream consumer" textDecoder id

kafkaEventsGroupSetting :: Setting Text
kafkaEventsGroupSetting = publicSettingWithRenderer kafkaEventsGroupKey "Consumer group id for the integration event consumer" textDecoder id

kafkaIncludeAgentActorsSetting :: Setting Bool
kafkaIncludeAgentActorsSetting =
  publicShowSetting
    kafkaIncludeAgentActorsKey
    "Match agent-produced activities too (meta-detectors; off is the feedback guard)"
    boolDecoder

httpHostSetting :: Setting Text
httpHostSetting =
  publicSettingWithRenderer
    httpHostKey
    "Interface the API binds; 127.0.0.1 stays local, * binds every interface"
    textDecoder
    id

httpPortSetting :: Setting Port
httpPortSetting =
  publicSettingWithRenderer
    httpPortKey
    "TCP port the public HTTP API binds"
    portDecoder
    (Text.pack . show . portNumber)

-- | Decode a port through the bounded integer decoder, then range-check it.
--
-- Built from the public decoder combinators so that both a native YAML number
-- and a textual environment value are accepted, and so that a rejected value
-- reports the accepted range without echoing what was supplied.
portDecoder :: Decoder Port
portDecoder =
  decoder
    ( \key raw ->
        case runDecoder (boundedIntegralDecoder @Int) key raw of
          Left _ -> Left (decodeFailure key portExpectation)
          Right value -> either (const (Left (decodeFailure key portExpectation))) Right (mkPort value)
    )

sinksKawaBaseUrlSetting :: Setting Text
sinksKawaBaseUrlSetting = publicSettingWithRenderer sinksKawaBaseUrlKey "Base URL of the kawa ingest doorway" textDecoder id

sinksKawaSourceSegmentSetting :: Setting Text
sinksKawaSourceSegmentSetting = publicSettingWithRenderer sinksKawaSourceSegmentKey "Source segment kawa attributes ingested activity to" textDecoder id

sinksKizashiBaseUrlSetting :: Setting Text
sinksKizashiBaseUrlSetting = publicSettingWithRenderer sinksKizashiBaseUrlKey "Base URL of the kizashi signal service" textDecoder id

sinksKizashiDefaultRecipientSetting :: Setting Text
sinksKizashiDefaultRecipientSetting = publicSettingWithRenderer sinksKizashiDefaultRecipientKey "Recipient used when a signal declares none" textDecoder id

sinksDanwaBaseUrlSetting :: Setting Text
sinksDanwaBaseUrlSetting = publicSettingWithRenderer sinksDanwaBaseUrlKey "Base URL of the danwa conversation server" textDecoder id

sinksDanwaAgentParticipantSetting :: Setting Text
sinksDanwaAgentParticipantSetting = publicSettingWithRenderer sinksDanwaAgentParticipantKey "danwa participant id Shikigami authors messages as" textDecoder id

behaviorProviderSetting :: Setting ProviderChoice
behaviorProviderSetting =
  publicSettingWithRenderer
    behaviorProviderKey
    "Model provider the Skill behavior arm dispatches with: stub calls no model, anthropic calls a real one"
    (enumDecoder [("stub", ChooseStub), ("anthropic", ChooseAnthropic)])
    renderProviderChoice

-- | Decoded against baikai's catalog, so an unknown id is rejected at
-- resolution with the accepted ids in the message rather than by Anthropic on
-- the first job.
behaviorModelSetting :: Setting Model
behaviorModelSetting =
  publicSettingWithRenderer
    behaviorModelKey
    "Anthropic model the Skill behavior arm dispatches with, by upstream model id"
    (enumDecoder [(modelId model, model) | model <- anthropicModels])
    modelId

anthropicApiKeySetting :: Setting SecretText
anthropicApiKeySetting =
  secretSetting
    anthropicApiKeyKey
    "Anthropic API key, required when behavior.provider is anthropic"
    (SecretText <$> textDecoder)

-- ── Stable keys ─────────────────────────────────────────────────────────────

-- Keys are the deployment contract: renaming one silently ignores an operator's
-- configured value, so they are written once here and referenced everywhere
-- else.

databaseConnectionStringKey :: Key
databaseConnectionStringKey = stableKey "database.connection_string"

agentsDirectoryKey :: Key
agentsDirectoryKey = stableKey "agents.directory"

kafkaBrokerKey :: Key
kafkaBrokerKey = stableKey "kafka.broker"

kafkaActivityTopicKey :: Key
kafkaActivityTopicKey = stableKey "kafka.activity.topic"

kafkaEventsTopicKey :: Key
kafkaEventsTopicKey = stableKey "kafka.events.topic"

kafkaStreamGroupKey :: Key
kafkaStreamGroupKey = stableKey "kafka.groups.stream"

kafkaEventsGroupKey :: Key
kafkaEventsGroupKey = stableKey "kafka.groups.events"

kafkaIncludeAgentActorsKey :: Key
kafkaIncludeAgentActorsKey = stableKey "kafka.include_agent_actors"

httpHostKey :: Key
httpHostKey = stableKey "http.host"

httpPortKey :: Key
httpPortKey = stableKey "http.port"

sinksKawaBaseUrlKey :: Key
sinksKawaBaseUrlKey = stableKey "sinks.kawa.base_url"

sinksKawaSourceSegmentKey :: Key
sinksKawaSourceSegmentKey = stableKey "sinks.kawa.source_segment"

sinksKizashiBaseUrlKey :: Key
sinksKizashiBaseUrlKey = stableKey "sinks.kizashi.base_url"

sinksKizashiDefaultRecipientKey :: Key
sinksKizashiDefaultRecipientKey = stableKey "sinks.kizashi.default_recipient"

sinksDanwaBaseUrlKey :: Key
sinksDanwaBaseUrlKey = stableKey "sinks.danwa.base_url"

sinksDanwaAgentParticipantKey :: Key
sinksDanwaAgentParticipantKey = stableKey "sinks.danwa.agent_participant"

behaviorProviderKey :: Key
behaviorProviderKey = stableKey "behavior.provider"

behaviorModelKey :: Key
behaviorModelKey = stableKey "behavior.model"

anthropicApiKeyKey :: Key
anthropicApiKeyKey = stableKey "credentials.providers.anthropic.api_key"

-- | Every key this declaration accepts, in schema order.
--
-- Exists so a test can assert the accepted surface has not drifted, and so
-- documentation can be generated from the declaration rather than transcribed
-- from it.
declaredKeys :: [Key]
declaredKeys = fmap schemaSettingKey (schemaPossible appConfigSchema)

-- | Parse a key that is a compile-time constant of this module.
--
-- A malformed key here is a programming error, not an operator error, so it
-- fails loudly rather than becoming a runtime branch. The test suite forces
-- 'declaredKeys', which forces every one of them.
stableKey :: Text -> Key
stableKey value = either (\problem -> error (Text.unpack value <> ": invalid configuration key: " <> show problem)) id (parseKey value)

-- ── Environment bindings ────────────────────────────────────────────────────

-- | Every environment variable this repository accepts, bound explicitly.
--
-- Explicit, not prefix-scanned: a typo in a variable name must be a variable
-- that does nothing rather than a value that silently lands on the wrong key.
-- Two variables keep an unprefixed spelling. @PG_CONNECTION_STRING@ is what the
-- development shell in @nix\/haskell.nix@ exports and what deployments already
-- set. @ANTHROPIC_API_KEY@ is the name the whole ecosystem uses for that
-- credential — baikai's own fallback reads it, developers already have it
-- exported, and secret stores already publish it under that name — so binding it
-- here is what keeps the value flowing through Settei's precedence and redaction
-- instead of being read behind Settei's back. Everything else uses the
-- @SHIKIGAMI_@ prefix and mirrors its key.
--
-- Validated once at module level. The test suite forces this value so that an
-- invalid edit — a duplicate variable, two variables aimed at the same key, or
-- keys that structurally overlap — fails in tests rather than at process
-- startup.
environmentBindings :: Bindings
environmentBindings =
  either
    (error . Text.unpack . renderEnvErrorsText)
    id
    ( bindings
        [ binding (EnvName "PG_CONNECTION_STRING") databaseConnectionStringKey,
          binding (EnvName "SHIKIGAMI_AGENTS_DIRECTORY") agentsDirectoryKey,
          binding (EnvName "SHIKIGAMI_KAFKA_BROKER") kafkaBrokerKey,
          binding (EnvName "SHIKIGAMI_KAFKA_ACTIVITY_TOPIC") kafkaActivityTopicKey,
          binding (EnvName "SHIKIGAMI_KAFKA_EVENTS_TOPIC") kafkaEventsTopicKey,
          binding (EnvName "SHIKIGAMI_KAFKA_STREAM_GROUP") kafkaStreamGroupKey,
          binding (EnvName "SHIKIGAMI_KAFKA_EVENTS_GROUP") kafkaEventsGroupKey,
          binding (EnvName "SHIKIGAMI_KAFKA_INCLUDE_AGENT_ACTORS") kafkaIncludeAgentActorsKey,
          binding (EnvName "SHIKIGAMI_HTTP_HOST") httpHostKey,
          binding (EnvName "SHIKIGAMI_HTTP_PORT") httpPortKey,
          binding (EnvName "SHIKIGAMI_SINKS_KAWA_BASE_URL") sinksKawaBaseUrlKey,
          binding (EnvName "SHIKIGAMI_SINKS_KAWA_SOURCE_SEGMENT") sinksKawaSourceSegmentKey,
          binding (EnvName "SHIKIGAMI_SINKS_KIZASHI_BASE_URL") sinksKizashiBaseUrlKey,
          binding (EnvName "SHIKIGAMI_SINKS_KIZASHI_DEFAULT_RECIPIENT") sinksKizashiDefaultRecipientKey,
          binding (EnvName "SHIKIGAMI_SINKS_DANWA_BASE_URL") sinksDanwaBaseUrlKey,
          binding (EnvName "SHIKIGAMI_SINKS_DANWA_AGENT_PARTICIPANT") sinksDanwaAgentParticipantKey,
          binding (EnvName "SHIKIGAMI_BEHAVIOR_PROVIDER") behaviorProviderKey,
          binding (EnvName "SHIKIGAMI_BEHAVIOR_MODEL") behaviorModelKey,
          binding (EnvName "ANTHROPIC_API_KEY") anthropicApiKeyKey
        ]
    )

-- ── Which binary needs what ─────────────────────────────────────────────────

-- | One running Shikigami process.
--
-- A role exists so that a single declaration can still express per-binary
-- requirements: @shikigami-worker@ cannot start without a database, while
-- @shikigami-run-behavior@ never opens one, and @--check-config@ should say so
-- for the binary it was invoked on rather than for Shikigami in general.
data Role
  = ServerRole
  | AdminRole
  | WorkerRole
  | SchedulerRole
  | StreamConsumerRole
  | EventConsumerRole
  | RunBehaviorRole
  | AgentRunRole
  | MigrateRole
  deriving stock (Generic, Eq, Ord, Show, Bounded, Enum)

-- | The installed name of the binary that plays a role, for diagnostics.
roleBinary :: Role -> Text
roleBinary = \case
  ServerRole -> "shikigami-server"
  AdminRole -> "shikigami"
  WorkerRole -> "shikigami-worker"
  SchedulerRole -> "shikigami-scheduler"
  StreamConsumerRole -> "shikigami-consume-stream"
  EventConsumerRole -> "shikigami-consume-events"
  RunBehaviorRole -> "shikigami-run-behavior"
  AgentRunRole -> "shikigami-agent-run"
  MigrateRole -> "shikigami-migrate"

-- | Keys a role cannot start without.
--
-- Only the database connection string is conditional today. @shikigami@ is
-- absent from the database list on purpose: @shikigami validate@ and
-- @shikigami render-lifecycle@ read a manifest and never connect, so requiring a
-- connection string for the whole command line would make an offline command
-- fail. Its database-using subcommands ask for the value at the point of use.
roleRequiredKeys :: Role -> [Key]
roleRequiredKeys = \case
  WorkerRole -> [databaseConnectionStringKey]
  SchedulerRole -> [databaseConnectionStringKey]
  StreamConsumerRole -> [databaseConnectionStringKey]
  EventConsumerRole -> [databaseConnectionStringKey]
  AgentRunRole -> [databaseConnectionStringKey]
  MigrateRole -> [databaseConnectionStringKey]
  ServerRole -> []
  AdminRole -> []
  RunBehaviorRole -> []

-- | Which of a role's required keys resolution did not supply.
--
-- Run after resolution succeeds, including under @--check-config@, so that a
-- worker started without a connection string fails at configuration time with a
-- named key rather than later inside the store connection.
missingRequirements :: Role -> AppConfig -> [Key]
missingRequirements role config =
  [ key
  | key <- roleRequiredKeys role,
    not (satisfied key)
  ]
  where
    satisfied key
      | key == databaseConnectionStringKey = maybe False (not . Text.null . revealSecretText) (databaseUrl config)
      | otherwise = True
