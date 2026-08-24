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
    DirectorySettings (..),
    Port,
    mkPort,
    portNumber,
    ByteLimit,
    mkByteLimit,
    byteLimitBytes,

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
    defaultHealthPort,
    healthPortFor,

    -- * Stable keys
    databaseConnectionStringKey,
    agentsDirectoryKey,
    agentsStrictKey,
    directoryModeKey,
    directoryFilePathKey,
    directoryRefreshIntervalSecondsKey,
    delegationBudgetKey,
    schedulerCatchUpKey,
    kafkaBrokerKey,
    kafkaActivityTopicKey,
    kafkaEventsTopicKey,
    kafkaStreamGroupKey,
    kafkaEventsGroupKey,
    kafkaIncludeAgentActorsKey,
    kafkaDeadLetterQueueKey,
    httpHostKey,
    httpPortKey,
    httpRequestMaxBytesKey,
    httpResponseMaxBytesKey,
    healthPortKey,
    workerRunTimeoutSecondsKey,
    approvalRequireKey,
    approvalChannelKey,
    approvalDeadlineSecondsKey,
    conversationIdleTimeoutSecondsKey,
    behaviorProviderKey,
    behaviorModelKey,
    anthropicApiKeyKey,
    kawaTokenKey,
    kizashiTokenKey,
    kanmonTokenKey,
    danwaTokenKey,
    sinksKawaBaseUrlKey,
    sinksKawaSourceSegmentKey,
    sinksKizashiBaseUrlKey,
    sinksKizashiDefaultRecipientKey,
    sinksKanmonBaseUrlKey,
    sinksDanwaBaseUrlKey,
    sinksDanwaAgentParticipantKey,
    sinksReiBaseUrlKey,
    declaredKeys,
  )
where

import Baikai.Api (Api (AnthropicMessages))
import Baikai.Model (Model, api, modelId, provider)
import Baikai.Models.Generated (allModels, anthropic_claude_sonnet_4_6)
import Data.Bifunctor (first)
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, nominalDiffTimeToSeconds, secondsToNominalDiffTime)
import GHC.Generics (Generic)
import Pgmq (QueueName, parseQueueName, queueNameToText)
import Settei
import Settei.Env
import Shikigami.Agent.Approval
  ( ApprovalChannel (ViaDanwa),
    parseApprovalChannel,
    parseRequiredSinkKinds,
    renderApprovalChannel,
    renderRequiredSinkKinds,
  )
import Shikigami.Agent.Decl
  ( DelegationBudget,
    defaultDelegationBudget,
    delegationBudgetNatural,
    mkDelegationBudget,
  )
import Shikigami.Directory (DirectorySettings (..))
import Shikigami.Sink.Permission (SinkKind)
import Shikigami.Trigger.Schedule (CatchUpPolicy (..))

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

-- | A validated in-memory bound for an HTTP request or response body.
--
-- The lower bound keeps accidental zero-byte limits from disabling every sink,
-- while the upper bound prevents a configuration typo from defeating the
-- allocation guard. The constructor stays private so HTTP code can rely on the
-- invariant without checking it again.
newtype ByteLimit = ByteLimit Int
  deriving stock (Generic, Eq, Ord)

-- | Build a body-size limit between 1 KiB and 64 MiB, inclusive.
mkByteLimit :: Int -> Either Text ByteLimit
mkByteLimit value
  | value >= minByteLimit && value <= maxByteLimit = Right (ByteLimit value)
  | otherwise = Left byteLimitExpectation

-- | The body-size limit in bytes.
byteLimitBytes :: ByteLimit -> Int
byteLimitBytes (ByteLimit value) = value

minByteLimit :: Int
minByteLimit = 1_024

maxByteLimit :: Int
maxByteLimit = 67_108_864

byteLimitExpectation :: Text
byteLimitExpectation = "a whole number of bytes between 1024 and 67108864"

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
    -- | Whether a manifest that fails to load refuses the process's startup.
    -- Off by default: upgrading must not turn a deployment that has been
    -- tolerating a broken manifest into a failed deploy on its own.
    agentsStrict :: !Bool,
    -- | Principal lifecycle directory and its refresh policy. Disabled by
    -- default so existing deployments retain their pre-directory behavior.
    directorySettings :: !DirectorySettings,
    -- | Root-run-wide maximum number of distinct descendant workflows when an
    -- agent declaration does not choose its own limit.
    delegationBudget :: !DelegationBudget,
    -- | What the scheduler does about cron minutes that passed while it was
    -- down. Skip-missed by default: a cron agent's value is "run about now",
    -- not "run once for every minute I was offline".
    schedulerCatchUp :: !CatchUpPolicy,
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
    -- | Durable PGMQ target for Kafka records that cannot be decoded.
    kafkaDeadLetterQueue :: !QueueName,
    -- | Interface the public HTTP API binds.
    httpHost :: !Text,
    -- | Port the public HTTP API binds.
    httpPort :: !Port,
    -- | Largest encoded body an outbound sink request may carry.
    httpRequestMaxBytes :: !ByteLimit,
    -- | Largest body an outbound sink response may return.
    httpResponseMaxBytes :: !ByteLimit,
    -- | Port a probe listener binds, when an operator names one.
    --
    -- 'Maybe' rather than a declared default because the sensible default is
    -- per-role — four worker processes on one host cannot share a port — and one
    -- declaration cannot carry four defaults. 'healthPortFor' applies the role's
    -- default when this is absent; 'defaultHealthPort' is the table.
    healthPort :: !(Maybe Port),
    -- | Maximum duration of one synchronous external behavior attempt.
    runTimeout :: !NominalDiffTime,
    -- | Maximum duration an approval or flow acknowledgement may remain open.
    approvalRequiredSinks :: !(Set SinkKind),
    approvalChannel :: !ApprovalChannel,
    approvalDeadline :: !NominalDiffTime,
    -- | How long a parked conversation waits for its next human message before
    -- ending its epoch and completing its kioku session.
    --
    -- This is the /between-turns/ window, not a bound on a turn: a turn is
    -- bounded by 'runTimeout'. A conversation that times out is not an error —
    -- the next message opens a fresh epoch chained to the one that closed.
    conversationIdleTimeout :: !NominalDiffTime,
    -- | Base URL of the kawa ingest doorway.
    kawaBaseUrl :: !Text,
    -- | Source segment kawa attributes ingested activity to.
    kawaSourceSegment :: !Text,
    -- | Bearer token sent to kawa, when that sink requires authentication.
    kawaToken :: !(Maybe SecretText),
    -- | Base URL of the kizashi signal service.
    kizashiBaseUrl :: !Text,
    -- | Recipient used when a declared signal names none.
    kizashiDefaultRecipient :: !Text,
    -- | Bearer token sent to kizashi, when that sink requires authentication.
    kizashiToken :: !(Maybe SecretText),
    -- | Base URL of the Kanmon guarded channel-action service.
    kanmonBaseUrl :: !Text,
    -- | Bearer token authenticating Shikigami to Kanmon. Provider credentials
    -- remain downstream and never enter this configuration.
    kanmonToken :: !(Maybe SecretText),
    -- | Base URL of the danwa conversation server.
    danwaBaseUrl :: !Text,
    -- | danwa participant id Shikigami authors messages as.
    danwaAgentParticipant :: !Text,
    -- | Bearer token sent to danwa, when that sink requires authentication.
    danwaToken :: !(Maybe SecretText),
    -- | Base URL of a rei ingestion endpoint, if one exists.
    --
    -- The only sink base URL with no default, because rei has no HTTP surface to
    -- point one at. Absent means a @ReiAction@ sink fails visibly into the outbox
    -- retry path rather than reporting a delivery that never happened.
    reiBaseUrl :: !(Maybe Text),
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
-- Every unconditional setting except 'databaseUrl' has a declared default, so
-- a process starts with no configuration at all and behaves the way the
-- development shell expects. File directory mode conditionally requires its
-- path. Defaults are declared through Settei rather than baked into a built-in
-- source so that @--explain-config@ can say which rule supplied a value and why.
appConfig :: Config AppConfig
appConfig =
  AppConfig
    <$> optional databaseConnectionStringSetting
    <*> withDefault agentsDirectorySetting (constant "agents-directory" "Manifests live in ./agents relative to the working directory" "agents")
    <*> withDefault agentsStrictSetting (constant "lenient-agents" "Report a manifest that fails to load, but start anyway" False)
    <*> directorySettingsConfig
    <*> withDefault delegationBudgetSetting (constant "delegation-budget" "Bound the complete descendant tree of a root run" defaultDelegationBudget)
    <*> withDefault schedulerCatchUpSetting (constant "skip-missed" "Waking late arms the next future tick instead of replaying every missed minute" SkipMissed)
    <*> withDefault kafkaBrokerSetting (constant "kafka-broker" "Use the development shell's local broker" "127.0.0.1:9092")
    <*> withDefault kafkaActivityTopicSetting (constant "activity-topic" "The canonical activity stream topic" "activity.v1")
    <*> withDefault kafkaEventsTopicSetting (constant "events-topic" "danwa's addressed-message integration event" "danwa.message-addressed.v1")
    <*> withDefault kafkaStreamGroupSetting (constant "stream-group" "One consumer group per stream role" "shikigami-stream")
    <*> withDefault kafkaEventsGroupSetting (constant "events-group" "One consumer group per stream role" "shikigami-events")
    <*> withDefault kafkaIncludeAgentActorsSetting (constant "feedback-guard" "Ignore agent-produced activities so an agent cannot trigger itself" False)
    <*> withDefault kafkaDeadLetterQueueSetting (constant "stream-dead-letter-queue" "Keep poison Kafka records in Postgres before advancing their offsets" defaultKafkaDeadLetterQueue)
    <*> withDefault httpHostSetting (constant "loopback" "Keep a development server off the network" "127.0.0.1")
    <*> withDefault httpPortSetting (constant "http-port" "The conventional Shikigami API port" (Port 8080))
    <*> withDefault httpRequestMaxBytesSetting (constant "http-request-limit" "Bound encoded sink request bodies to 8 MiB" (ByteLimit 8_388_608))
    <*> withDefault httpResponseMaxBytesSetting (constant "http-response-limit" "Bound sink response bodies to 8 MiB" (ByteLimit 8_388_608))
    <*> optional healthPortSetting
    <*> withDefault workerRunTimeoutSecondsSetting (constant "worker-run-timeout" "Bound one synchronous behavior attempt" (secondsToNominalDiffTime 300))
    <*> withDefault approvalRequireSetting (constant "approval-auto-approve" "Ordinary sinks do not require approval" mempty)
    <*> withDefault approvalChannelSetting (constant "approval-danwa" "Send human approval asks through Danwa" ViaDanwa)
    <*> withDefault approvalDeadlineSecondsSetting (constant "approval-deadline" "Bound approval and acknowledgement waits" (secondsToNominalDiffTime 900))
    <*> withDefault conversationIdleTimeoutSecondsSetting (constant "conversation-idle-timeout" "End a conversation epoch after half an hour of silence" (secondsToNominalDiffTime 1800))
    <*> withDefault sinksKawaBaseUrlSetting (constant "local-kawa" "The local kawa (or stub-kawa) doorway" "http://localhost:8088")
    <*> withDefault sinksKawaSourceSegmentSetting (constant "kawa-source" "This repository's ingest source segment" "shinzui/shikigami")
    <*> optional kawaTokenSetting
    <*> withDefault sinksKizashiBaseUrlSetting (constant "local-kizashi" "The local kizashi service" "http://localhost:8089")
    <*> withDefault sinksKizashiDefaultRecipientSetting (constant "kizashi-recipient" "Recipient used when a signal declares none" "recipient:default")
    <*> optional kizashiTokenSetting
    <*> withDefault sinksKanmonBaseUrlSetting (constant "local-kanmon" "The local Kanmon channel-action service" "http://localhost:8090")
    <*> optional kanmonTokenSetting
    <*> withDefault sinksDanwaBaseUrlSetting (constant "local-danwa" "The local danwa server" "http://localhost:8080")
    <*> withDefault sinksDanwaAgentParticipantSetting (constant "danwa-agent" "Participant id Shikigami authors messages as" "part_shikigami")
    <*> optional danwaTokenSetting
    <*> optional sinksReiBaseUrlSetting
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

-- | Directory mode is conditional so file mode cannot resolve without a path,
-- while disabled deployments are not asked for a meaningless one.
directorySettingsConfig :: Config DirectorySettings
directorySettingsConfig =
  maybe DirectoryDisabled (uncurry DirectoryFile)
    <$> whenEq
      (withDefault directoryModeSetting (constant "directory-disabled" "Preserve lifecycle behavior until a directory source is configured" DisableDirectory))
      ReadDirectoryFile
      ( (,)
          <$> required directoryFilePathSetting
          <*> withDefault directoryRefreshIntervalSecondsSetting (constant "directory-refresh" "Refresh the principal directory every five seconds" (secondsToNominalDiffTime 5))
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
-- Resolution cannot fail here: every unconditional setting except 'databaseUrl'
-- has a declared default, 'databaseUrl' is optional, and file directory mode is
-- not selected. A failure would mean the declaration itself is broken, which is
-- a programming error rather than an operator error.
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

agentsStrictSetting :: Setting Bool
agentsStrictSetting =
  publicShowSetting
    agentsStrictKey
    "Refuse to start when any agent manifest fails to load (off reports the failure and starts)"
    boolDecoder

data DirectoryMode = DisableDirectory | ReadDirectoryFile
  deriving stock (Generic, Eq, Show)

directoryModeSetting :: Setting DirectoryMode
directoryModeSetting =
  publicSettingWithRenderer
    directoryModeKey
    "Principal lifecycle directory mode: disabled preserves compatibility, file reads a JSON projection"
    (enumDecoder [("disabled", DisableDirectory), ("file", ReadDirectoryFile)])
    \case
      DisableDirectory -> "disabled"
      ReadDirectoryFile -> "file"

directoryFilePathSetting :: Setting FilePath
directoryFilePathSetting =
  publicSettingWithRenderer
    directoryFilePathKey
    "Path to the JSON principal projection, required in file mode"
    (Text.unpack <$> textDecoder)
    Text.pack

directoryRefreshIntervalSecondsSetting :: Setting NominalDiffTime
directoryRefreshIntervalSecondsSetting =
  publicSettingWithRenderer
    directoryRefreshIntervalSecondsKey
    "Seconds between principal directory refresh attempts (1-86400)"
    positiveDurationDecoder
    renderDurationSeconds

delegationBudgetSetting :: Setting DelegationBudget
delegationBudgetSetting =
  publicSettingWithRenderer
    delegationBudgetKey
    "Maximum distinct descendants per root agent run when its manifest does not override the limit (0-1000)"
    delegationBudgetDecoder
    (Text.pack . show . delegationBudgetNatural)

delegationBudgetDecoder :: Decoder DelegationBudget
delegationBudgetDecoder =
  decoder
    ( \key raw ->
        case runDecoder (boundedIntegralDecoder @Int) key raw of
          Left _ -> Left (decodeFailure key delegationBudgetExpectation)
          Right value
            | value >= 0 -> either (const (Left (decodeFailure key delegationBudgetExpectation))) Right (mkDelegationBudget (fromIntegral value))
          Right _ -> Left (decodeFailure key delegationBudgetExpectation)
    )

delegationBudgetExpectation :: Text
delegationBudgetExpectation = "a whole number between 0 and 1000 inclusive"

schedulerCatchUpSetting :: Setting CatchUpPolicy
schedulerCatchUpSetting =
  publicSettingWithRenderer
    schedulerCatchUpKey
    "What the scheduler does about cron minutes that passed while it was down: skip_missed arms the next future tick, fire_all replays every missed minute"
    (enumDecoder [("skip_missed", SkipMissed), ("fire_all", FireAll)])
    renderCatchUpPolicy

renderCatchUpPolicy :: CatchUpPolicy -> Text
renderCatchUpPolicy = \case
  SkipMissed -> "skip_missed"
  FireAll -> "fire_all"

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

kafkaDeadLetterQueueSetting :: Setting QueueName
kafkaDeadLetterQueueSetting =
  publicSettingWithRenderer
    kafkaDeadLetterQueueKey
    "PGMQ queue that durably stores undecodable Kafka records before their offsets advance"
    queueNameDecoder
    queueNameToText

queueNameDecoder :: Decoder QueueName
queueNameDecoder =
  decoder
    ( \key raw ->
        case runDecoder textDecoder key raw of
          Right value -> either (const (Left (decodeFailure key queueNameExpectation))) Right (parseQueueName value)
          Left _ -> Left (decodeFailure key queueNameExpectation)
    )

queueNameExpectation :: Text
queueNameExpectation = "a non-empty PGMQ queue name of at most 47 lowercase letters, digits, and underscores"

defaultKafkaDeadLetterQueue :: QueueName
defaultKafkaDeadLetterQueue =
  either (error . show) id (parseQueueName "shikigami_stream_dead_letters")

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

httpRequestMaxBytesSetting :: Setting ByteLimit
httpRequestMaxBytesSetting =
  publicSettingWithRenderer
    httpRequestMaxBytesKey
    "Maximum encoded request body sent to an outbound sink, in bytes (1024-67108864)"
    byteLimitDecoder
    (Text.pack . show . byteLimitBytes)

httpResponseMaxBytesSetting :: Setting ByteLimit
httpResponseMaxBytesSetting =
  publicSettingWithRenderer
    httpResponseMaxBytesKey
    "Maximum response body accepted from an outbound sink, in bytes (1024-67108864)"
    byteLimitDecoder
    (Text.pack . show . byteLimitBytes)

healthPortSetting :: Setting Port
healthPortSetting =
  publicSettingWithRenderer
    healthPortKey
    "TCP port the probe listener binds; defaults per role (8091 worker, 8092 scheduler, 8093 stream, 8094 events)"
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

byteLimitDecoder :: Decoder ByteLimit
byteLimitDecoder =
  decoder
    ( \key raw ->
        case runDecoder (boundedIntegralDecoder @Int) key raw of
          Left _ -> Left (decodeFailure key byteLimitExpectation)
          Right value -> either (const (Left (decodeFailure key byteLimitExpectation))) Right (mkByteLimit value)
    )

workerRunTimeoutSecondsSetting :: Setting NominalDiffTime
workerRunTimeoutSecondsSetting =
  publicSettingWithRenderer
    workerRunTimeoutSecondsKey
    "Maximum seconds for one synchronous external behavior attempt (1-86400)"
    positiveDurationDecoder
    renderDurationSeconds

approvalDeadlineSecondsSetting :: Setting NominalDiffTime
approvalDeadlineSecondsSetting =
  publicSettingWithRenderer
    approvalDeadlineSecondsKey
    "Maximum seconds to wait for an approval or flow acknowledgement (1-86400)"
    positiveDurationDecoder
    renderDurationSeconds

approvalRequireSetting :: Setting (Set SinkKind)
approvalRequireSetting =
  publicSettingWithRenderer
    approvalRequireKey
    "Comma-separated sink kinds requiring approval; empty means auto-approve"
    (decoder decodeRequiredSinks)
    renderRequiredSinkKinds
  where
    decodeRequiredSinks key raw =
      case runDecoder textDecoder key raw of
        Left _ -> Left (decodeFailure key approvalRequireExpectation)
        Right value -> first (const (decodeFailure key approvalRequireExpectation)) (parseRequiredSinkKinds value)

approvalChannelSetting :: Setting ApprovalChannel
approvalChannelSetting =
  publicSettingWithRenderer
    approvalChannelKey
    "Channel used for human approval asks (danwa or kizashi)"
    (decoder decodeChannel)
    renderApprovalChannel
  where
    decodeChannel key raw =
      case runDecoder textDecoder key raw of
        Left _ -> Left (decodeFailure key approvalChannelExpectation)
        Right value -> first (const (decodeFailure key approvalChannelExpectation)) (parseApprovalChannel value)

approvalRequireExpectation :: Text
approvalRequireExpectation =
  "an empty value or a comma-separated unique set of KawaDigest, KizashiSignal, ReiAction, DanwaConversation, ChannelEgress"

approvalChannelExpectation :: Text
approvalChannelExpectation = "one of danwa, kizashi"

conversationIdleTimeoutSecondsSetting :: Setting NominalDiffTime
conversationIdleTimeoutSecondsSetting =
  publicSettingWithRenderer
    conversationIdleTimeoutSecondsKey
    "Maximum seconds a parked conversation waits for its next message before completing (1-86400)"
    positiveDurationDecoder
    renderDurationSeconds

-- | One day is well below @maxBound :: Int@ after conversion to microseconds on
-- every 64-bit platform supported by this repository's deployment flake, while
-- still allowing operational budgets far above the defaults.
positiveDurationDecoder :: Decoder NominalDiffTime
positiveDurationDecoder =
  decoder
    ( \key raw ->
        case runDecoder (boundedIntegralDecoder @Int) key raw of
          Right seconds
            | seconds >= 1 && seconds <= maxDurationSeconds -> Right (secondsToNominalDiffTime (fromIntegral seconds))
          _ -> Left (decodeFailure key durationExpectation)
    )

maxDurationSeconds :: Int
maxDurationSeconds = 86_400

durationExpectation :: Text
durationExpectation = "a whole number of seconds between 1 and 86400"

renderDurationSeconds :: NominalDiffTime -> Text
renderDurationSeconds duration =
  Text.pack (show (floor (nominalDiffTimeToSeconds duration) :: Integer))

sinksKawaBaseUrlSetting :: Setting Text
sinksKawaBaseUrlSetting = publicSettingWithRenderer sinksKawaBaseUrlKey "Base URL of the kawa ingest doorway" textDecoder id

sinksKawaSourceSegmentSetting :: Setting Text
sinksKawaSourceSegmentSetting = publicSettingWithRenderer sinksKawaSourceSegmentKey "Source segment kawa attributes ingested activity to" textDecoder id

kawaTokenSetting :: Setting SecretText
kawaTokenSetting =
  secretSetting
    kawaTokenKey
    "Bearer token for the kawa sink"
    (SecretText <$> textDecoder)

sinksKizashiBaseUrlSetting :: Setting Text
sinksKizashiBaseUrlSetting = publicSettingWithRenderer sinksKizashiBaseUrlKey "Base URL of the kizashi signal service" textDecoder id

sinksKizashiDefaultRecipientSetting :: Setting Text
sinksKizashiDefaultRecipientSetting = publicSettingWithRenderer sinksKizashiDefaultRecipientKey "Recipient used when a signal declares none" textDecoder id

kizashiTokenSetting :: Setting SecretText
kizashiTokenSetting =
  secretSetting
    kizashiTokenKey
    "Bearer token for the kizashi sink"
    (SecretText <$> textDecoder)

sinksKanmonBaseUrlSetting :: Setting Text
sinksKanmonBaseUrlSetting = publicSettingWithRenderer sinksKanmonBaseUrlKey "Base URL of the Kanmon channel-action service" textDecoder id

kanmonTokenSetting :: Setting SecretText
kanmonTokenSetting =
  secretSetting
    kanmonTokenKey
    "Bearer token authenticating Shikigami to Kanmon"
    (SecretText <$> textDecoder)

sinksDanwaBaseUrlSetting :: Setting Text
sinksDanwaBaseUrlSetting = publicSettingWithRenderer sinksDanwaBaseUrlKey "Base URL of the danwa conversation server" textDecoder id

sinksDanwaAgentParticipantSetting :: Setting Text
sinksDanwaAgentParticipantSetting = publicSettingWithRenderer sinksDanwaAgentParticipantKey "danwa participant id Shikigami authors messages as" textDecoder id

danwaTokenSetting :: Setting SecretText
danwaTokenSetting =
  secretSetting
    danwaTokenKey
    "Bearer token for the danwa sink"
    (SecretText <$> textDecoder)

-- | Deliberately without a default: there is no rei endpoint to default to.
sinksReiBaseUrlSetting :: Setting Text
sinksReiBaseUrlSetting =
  publicSettingWithRenderer
    sinksReiBaseUrlKey
    "Base URL of a rei ingestion endpoint; unset means ReiAction sinks fail visibly rather than silently"
    textDecoder
    id

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

agentsStrictKey :: Key
agentsStrictKey = stableKey "agents.strict"

directoryModeKey :: Key
directoryModeKey = stableKey "directory.mode"

directoryFilePathKey :: Key
directoryFilePathKey = stableKey "directory.file.path"

directoryRefreshIntervalSecondsKey :: Key
directoryRefreshIntervalSecondsKey = stableKey "directory.refresh_interval_seconds"

delegationBudgetKey :: Key
delegationBudgetKey = stableKey "delegation.default_budget"

schedulerCatchUpKey :: Key
schedulerCatchUpKey = stableKey "scheduler.catch_up"

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

kafkaDeadLetterQueueKey :: Key
kafkaDeadLetterQueueKey = stableKey "kafka.dead_letter.queue"

httpHostKey :: Key
httpHostKey = stableKey "http.host"

httpPortKey :: Key
httpPortKey = stableKey "http.port"

httpRequestMaxBytesKey :: Key
httpRequestMaxBytesKey = stableKey "http.request_max_bytes"

httpResponseMaxBytesKey :: Key
httpResponseMaxBytesKey = stableKey "http.response_max_bytes"

healthPortKey :: Key
healthPortKey = stableKey "health.port"

workerRunTimeoutSecondsKey :: Key
workerRunTimeoutSecondsKey = stableKey "worker.run_timeout_seconds"

approvalRequireKey :: Key
approvalRequireKey = stableKey "approval.require"

approvalChannelKey :: Key
approvalChannelKey = stableKey "approval.channel"

approvalDeadlineSecondsKey :: Key
approvalDeadlineSecondsKey = stableKey "approval.deadline_seconds"

conversationIdleTimeoutSecondsKey :: Key
conversationIdleTimeoutSecondsKey = stableKey "conversation.idle_timeout_seconds"

sinksKawaBaseUrlKey :: Key
sinksKawaBaseUrlKey = stableKey "sinks.kawa.base_url"

sinksKawaSourceSegmentKey :: Key
sinksKawaSourceSegmentKey = stableKey "sinks.kawa.source_segment"

sinksKizashiBaseUrlKey :: Key
sinksKizashiBaseUrlKey = stableKey "sinks.kizashi.base_url"

sinksKizashiDefaultRecipientKey :: Key
sinksKizashiDefaultRecipientKey = stableKey "sinks.kizashi.default_recipient"

sinksKanmonBaseUrlKey :: Key
sinksKanmonBaseUrlKey = stableKey "sinks.kanmon.base_url"

sinksDanwaBaseUrlKey :: Key
sinksDanwaBaseUrlKey = stableKey "sinks.danwa.base_url"

sinksDanwaAgentParticipantKey :: Key
sinksDanwaAgentParticipantKey = stableKey "sinks.danwa.agent_participant"

sinksReiBaseUrlKey :: Key
sinksReiBaseUrlKey = stableKey "sinks.rei.base_url"

behaviorProviderKey :: Key
behaviorProviderKey = stableKey "behavior.provider"

behaviorModelKey :: Key
behaviorModelKey = stableKey "behavior.model"

anthropicApiKeyKey :: Key
anthropicApiKeyKey = stableKey "credentials.providers.anthropic.api_key"

kawaTokenKey :: Key
kawaTokenKey = stableKey "credentials.sinks.kawa.token"

kizashiTokenKey :: Key
kizashiTokenKey = stableKey "credentials.sinks.kizashi.token"

kanmonTokenKey :: Key
kanmonTokenKey = stableKey "credentials.sinks.kanmon.token"

danwaTokenKey :: Key
danwaTokenKey = stableKey "credentials.sinks.danwa.token"

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
          binding (EnvName "SHIKIGAMI_AGENTS_STRICT") agentsStrictKey,
          binding (EnvName "SHIKIGAMI_DIRECTORY_MODE") directoryModeKey,
          binding (EnvName "SHIKIGAMI_DIRECTORY_FILE_PATH") directoryFilePathKey,
          binding (EnvName "SHIKIGAMI_DIRECTORY_REFRESH_INTERVAL_SECONDS") directoryRefreshIntervalSecondsKey,
          binding (EnvName "SHIKIGAMI_DELEGATION_DEFAULT_BUDGET") delegationBudgetKey,
          binding (EnvName "SHIKIGAMI_SCHEDULER_CATCH_UP") schedulerCatchUpKey,
          binding (EnvName "SHIKIGAMI_KAFKA_BROKER") kafkaBrokerKey,
          binding (EnvName "SHIKIGAMI_KAFKA_ACTIVITY_TOPIC") kafkaActivityTopicKey,
          binding (EnvName "SHIKIGAMI_KAFKA_EVENTS_TOPIC") kafkaEventsTopicKey,
          binding (EnvName "SHIKIGAMI_KAFKA_STREAM_GROUP") kafkaStreamGroupKey,
          binding (EnvName "SHIKIGAMI_KAFKA_EVENTS_GROUP") kafkaEventsGroupKey,
          binding (EnvName "SHIKIGAMI_KAFKA_INCLUDE_AGENT_ACTORS") kafkaIncludeAgentActorsKey,
          binding (EnvName "SHIKIGAMI_KAFKA_DEAD_LETTER_QUEUE") kafkaDeadLetterQueueKey,
          binding (EnvName "SHIKIGAMI_HTTP_HOST") httpHostKey,
          binding (EnvName "SHIKIGAMI_HTTP_PORT") httpPortKey,
          binding (EnvName "SHIKIGAMI_HTTP_REQUEST_MAX_BYTES") httpRequestMaxBytesKey,
          binding (EnvName "SHIKIGAMI_HTTP_RESPONSE_MAX_BYTES") httpResponseMaxBytesKey,
          binding (EnvName "SHIKIGAMI_HEALTH_PORT") healthPortKey,
          binding (EnvName "SHIKIGAMI_RUN_TIMEOUT_SECONDS") workerRunTimeoutSecondsKey,
          binding (EnvName "SHIKIGAMI_APPROVAL_REQUIRE") approvalRequireKey,
          binding (EnvName "SHIKIGAMI_APPROVAL_CHANNEL") approvalChannelKey,
          binding (EnvName "SHIKIGAMI_APPROVAL_DEADLINE_SECONDS") approvalDeadlineSecondsKey,
          binding (EnvName "SHIKIGAMI_CONVERSATION_IDLE_TIMEOUT_SECONDS") conversationIdleTimeoutSecondsKey,
          binding (EnvName "SHIKIGAMI_SINKS_KAWA_BASE_URL") sinksKawaBaseUrlKey,
          binding (EnvName "SHIKIGAMI_SINKS_KAWA_SOURCE_SEGMENT") sinksKawaSourceSegmentKey,
          binding (EnvName "SHIKIGAMI_SINKS_KIZASHI_BASE_URL") sinksKizashiBaseUrlKey,
          binding (EnvName "SHIKIGAMI_SINKS_KIZASHI_DEFAULT_RECIPIENT") sinksKizashiDefaultRecipientKey,
          binding (EnvName "SHIKIGAMI_SINKS_KANMON_BASE_URL") sinksKanmonBaseUrlKey,
          binding (EnvName "SHIKIGAMI_SINKS_DANWA_BASE_URL") sinksDanwaBaseUrlKey,
          binding (EnvName "SHIKIGAMI_SINKS_DANWA_AGENT_PARTICIPANT") sinksDanwaAgentParticipantKey,
          binding (EnvName "SHIKIGAMI_SINKS_REI_BASE_URL") sinksReiBaseUrlKey,
          binding (EnvName "SHIKIGAMI_KAWA_TOKEN") kawaTokenKey,
          binding (EnvName "SHIKIGAMI_KIZASHI_TOKEN") kizashiTokenKey,
          binding (EnvName "SHIKIGAMI_KANMON_TOKEN") kanmonTokenKey,
          binding (EnvName "SHIKIGAMI_DANWA_TOKEN") danwaTokenKey,
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

-- | The probe port a role binds when @health.port@ names none.
--
-- Four worker processes routinely run on one host, so they cannot share a
-- default; 8091-8094 keeps the whole local stack probeable without an operator
-- configuring anything. @Nothing@ means the role serves no probe listener of its
-- own: @shikigami-server@ answers the same two routes on its @http.port@
-- listener rather than opening a second socket, and the one-off commands
-- (@shikigami-run-behavior@, @shikigami-agent-run@, @shikigami-migrate@,
-- @shikigami@) run to completion instead of staying up to be probed.
defaultHealthPort :: Role -> Maybe Port
defaultHealthPort = \case
  WorkerRole -> Just (Port 8091)
  SchedulerRole -> Just (Port 8092)
  StreamConsumerRole -> Just (Port 8093)
  EventConsumerRole -> Just (Port 8094)
  ServerRole -> Nothing
  AdminRole -> Nothing
  RunBehaviorRole -> Nothing
  AgentRunRole -> Nothing
  MigrateRole -> Nothing

-- | Which port this role's probe listener binds, if it has one.
--
-- A configured @health.port@ wins for every role that serves probes. Setting it
-- on a role with no listener resolves fine and is then ignored, which is the
-- same thing that happens to @kafka.broker@ on the scheduler: one declaration
-- serves every binary, and a key a given role does not read is not an error.
healthPortFor :: Role -> AppConfig -> Maybe Port
healthPortFor role config =
  case defaultHealthPort role of
    Nothing -> Nothing
    roleDefault -> maybe roleDefault Just (healthPort config)

-- | Keys a role cannot start without.
--
-- Only the database connection string is conditional today. @shikigami@ is
-- absent from the database list on purpose: @shikigami validate@ and
-- @shikigami render-lifecycle@ read a manifest and never connect, so requiring a
-- connection string for the whole command line would make an offline command
-- fail. Its database-using subcommands ask for the value at the point of use.
--
-- @shikigami-server@ joined the list when its readiness probe started pinging
-- PostgreSQL: a server that cannot reach its database can never report ready, so
-- starting one without a connection string produces a process that binds a
-- socket and then fails every probe. Failing at configuration time, naming the
-- key, is the better outcome.
roleRequiredKeys :: Role -> [Key]
roleRequiredKeys = \case
  ServerRole -> [databaseConnectionStringKey]
  WorkerRole -> [databaseConnectionStringKey]
  SchedulerRole -> [databaseConnectionStringKey]
  StreamConsumerRole -> [databaseConnectionStringKey]
  EventConsumerRole -> [databaseConnectionStringKey]
  AgentRunRole -> [databaseConnectionStringKey]
  MigrateRole -> [databaseConnectionStringKey]
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
