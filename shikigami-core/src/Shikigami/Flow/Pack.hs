{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}

-- | The pack API: the one way a flow, a decision program or a program task
-- reaches a Shikigami executable (docs/adr/0129).
--
-- A /pack/ is a value of 'FlowPack'. An executable composes the packs it was
-- built with into a 'FlowRegistry' once, at start, and every later question —
-- which flow does this declaration name, which pack owns it, which decision
-- programs exist — is answered from that sealed value. There is no global
-- list, so a stock role and a distribution that adds packs differ only in the
-- list they pass to 'composeFlowRegistry'.
--
-- A flow is a body plus a pack-owned interpreter ('PackFlow'). The body is
-- typed against 'FlowEffects' and whatever capabilities the pack defines, and
-- cannot name 'IOE' or 'Store'; the interpreter may, and is the only reviewed
-- IO surface a pack has. 'kernelCapabilityFlow' is the common case of a body
-- that needs kernel capabilities alone.
module Shikigami.Flow.Pack
  ( -- * Pack names
    FlowPackName,
    FlowPackNameError (..),
    parseFlowPackName,
    flowPackNameText,

    -- * Packs
    FlowPack (..),
    PackFlow (..),
    kernelCapabilityFlow,
    FlowRunContext (..),
    RunModel (..),
    runModel,

    -- * Pack settings
    PackSetting (..),
    SettingShape (..),
    SettingDefault (..),
    PackSettings,
    packSettingValue,
    packSettingText,

    -- * The composed registry
    FlowRegistry,
    RegisteredFlow (..),
    FlowRegistryError (..),
    renderFlowRegistryError,
    composeFlowRegistry,
    composeFlowRegistryOrExit,
    registeredPacks,
    registeredFlows,
    registeredFlowNames,
    lookupFlow,
    lookupTask,
    decisionProgramRegistry,
    resultCodecRegistry,
    decisionServices,
    flowDeclarationErrors,
  )
where

import Baikai.Context (systemUser)
import Baikai.Response (flattenAssistantBlocks, flattenAssistantText, responseError)
import Baikai.ResponseFormat (ResponseFormat (JsonObject))
import Control.Lens ((&), (.~))
import Data.Aeson (Value, object, (.=))
import Data.ByteString qualified as ByteString
import Data.Char (isAsciiLower, isDigit)
import Data.Generics.Labels ()
import Data.List (find)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (UTCTime)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiro.Workflow.Types (WorkflowId, WorkflowName)
import Kioku.Id (SessionId)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Shikigami.Activity (ActivityEnvelope)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Principal (AgentIdentity, ResolvedAgentIdentity)
import Shikigami.App (AppEnv)
import Shikigami.Behavior.Compatibility (renderResponseCompatibilityError, validateResponseRequest)
import Shikigami.Behavior.Run (BehaviorEnv (..), completeBehaviorRequest)
import Shikigami.Decision.Contract (DecisionFailure)
import Shikigami.Decision.ModelCatalog (ModelCatalog, slotErrors)
import Shikigami.Directory (DirectoryHandle)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Flow (FlowDef (..), FlowEffects, flowDecisionSlotsFor)
import Shikigami.Flow.Decision (DecisionServices (..), decisionProviders)
import Shikigami.Log qualified as Log
import Shikigami.Pack.Setting (PackSetting (..), PackSettings, SettingDefault (..), SettingShape (..), packSettingText, packSettingValue)
import Shikigami.Program.Decision (ProgramRegistry, ResultCodecRegistry, SomeProgram, SomeResultCodec)
import Shikigami.Program.Decision qualified as Decision
import Shikigami.Program.Task (ProgramTask (..))
import Shikigami.Sink (GrantSource)
import System.Exit (exitFailure)

-- | A pack's checked name: lowercase ASCII words joined by @-@, 1 to 64 bytes.
-- It prefixes every durable label the pack's flows journal, so it is checked
-- once here and never rebuilt from text elsewhere (ADR-80).
newtype FlowPackName = FlowPackName Text
  deriving stock (Eq, Ord, Show)

data FlowPackNameError = EmptyFlowPackName | MalformedFlowPackName !Text
  deriving stock (Eq, Show)

parseFlowPackName :: Text -> Either FlowPackNameError FlowPackName
parseFlowPackName raw
  | Text.null raw = Left EmptyFlowPackName
  | ByteString.length (Text.encodeUtf8 raw) > 64 = Left (MalformedFlowPackName raw)
  | all word (Text.splitOn "-" raw) = Right (FlowPackName raw)
  | otherwise = Left (MalformedFlowPackName raw)
  where
    word part = not (Text.null part) && Text.all (\c -> isAsciiLower c || isDigit c) part

flowPackNameText :: FlowPackName -> Text
flowPackNameText (FlowPackName value) = value

-- | What one pack contributes. Each field arrives with its first executed
-- consumer (ADR-1); a later plan adds a field here and never defines a second
-- pack record.
data FlowPack = FlowPack
  { name :: !FlowPackName,
    flows :: ![PackFlow],
    decisionPrograms :: ![SomeProgram],
    -- | Codecs outlive retired programs (ADR-45).
    retainedCodecs :: ![SomeResultCodec],
    tasks :: ![ProgramTask],
    -- | The configuration keys this pack owns. An executable composed with the
    -- pack accepts them and hands their validated values to the pack's
    -- interpreters in 'FlowRunContext'.
    settings :: ![PackSetting]
  }

-- | A flow body plus the pack-owned interpreter that runs it.
--
-- @run@ is the only place a pack may use 'IOE' and 'Store'. It is also given
-- the store's error channel, because a journaled read that fails must reach
-- the workflow driver as the retryable store error it is. A pack with a
-- capability of its own builds it as @\\ctx -> interpretMine ctx . body@, where
-- @body@ lives in the pack's @bodies@ sublibrary and is typed
-- @(FlowEffects es, Mine :> es) => Value -> Eff es Value@. The kernel
-- installs its interpreters around @run@ and never names the pack's.
data PackFlow = PackFlow
  { definition :: !FlowDef,
    run :: !(forall es. (FlowEffects es, IOE :> es, Store :> es, Error StoreError :> es) => FlowRunContext -> Value -> Eff es Value)
  }

-- | A flow whose body needs only kernel capabilities, so it has no
-- interpreter of its own. The body's type still excludes 'IOE' and 'Store'.
kernelCapabilityFlow :: FlowDef -> (forall es. (FlowEffects es) => Value -> Eff es Value) -> PackFlow
kernelCapabilityFlow definition body = PackFlow {definition, run = \_ payload -> body payload}

-- | The read view of a run that the kernel builds once and hands a pack's
-- interpreter. A pack reads the run from here and never reaches into the
-- job or the kernel's composition record.
data FlowRunContext = FlowRunContext
  { agent :: !AgentDecl,
    identity :: !ResolvedAgentIdentity,
    session :: !SessionId,
    -- | The native workflow this run is an instance of, and its id.
    workflowName :: !WorkflowName,
    runId :: !WorkflowId,
    occurredAt :: !UTCTime,
    activity :: !ActivityEnvelope,
    executionRoot :: !(Maybe ExecutionRootId),
    directory :: !DirectoryHandle,
    declarations :: ![AgentDecl],
    -- | The identity the run job carries, before the kernel resolved it into
    -- 'identity'. A sink intent a pack prepares is attributed to this one.
    requestIdentity :: !AgentIdentity,
    -- | The delegating run and its session, when this run is a governed child.
    parentRunId :: !(Maybe WorkflowId),
    parentSession :: !(Maybe SessionId),
    -- | The run's model, already narrowed by its sanctioned profile.
    model :: !RunModel,
    -- | The validated settings of the composed packs.
    settings :: !PackSettings,
    -- | The kernel's stores, for an interpreter that records memory.
    app :: !AppEnv,
    -- | The grant source a sink intent prepared by the pack is checked against.
    grants :: !GrantSource
  }

-- | The one model call a pack interpreter may make: a system prompt and a
-- user prompt in, the text of one JSON-object response out. 'Left' carries a
-- rendered refusal or provider failure. The kernel builds it from the run's
-- behavior environment, so a pack reaches no provider, registry or option of
-- its own and cannot leave the call tuple a sanctioned profile allowed.
newtype RunModel = RunModel
  { completeJsonObject :: Text -> Text -> IO (Either Text Text)
  }

runModel :: BehaviorEnv -> RunModel
runModel env@BehaviorEnv {model, options} =
  RunModel \systemPrompt userPrompt -> do
    let context = systemUser systemPrompt userPrompt
        structuredOptions = options & #responseFormat .~ Just JsonObject
    case validateResponseRequest model structuredOptions context of
      Left refusal -> pure (Left (renderResponseCompatibilityError refusal))
      Right () -> do
        response <- completeBehaviorRequest env model context structuredOptions
        pure case responseError response of
          Just failure -> Left (Text.pack (show failure))
          Nothing -> Right (flattenAssistantText (flattenAssistantBlocks response))

data RegisteredFlow = RegisteredFlow
  { pack :: !FlowPackName,
    flow :: !PackFlow
  }

-- | The composed packs. Sealed: the constructor is private, so holding one is
-- the evidence that names are unique across packs and both decision
-- registries validated (ADR-81).
data FlowRegistry = FlowRegistry
  { packs :: ![FlowPackName],
    entries :: ![RegisteredFlow],
    taskEntries :: ![(FlowPackName, ProgramTask)],
    programs :: !ProgramRegistry,
    codecs :: !ResultCodecRegistry
  }

data FlowRegistryError
  = DuplicatePackName !FlowPackName
  | DuplicateFlowName !(DeclarationCoordinate "flow") !FlowPackName !FlowPackName
  | DuplicateTaskName !Text !FlowPackName !FlowPackName
  | DuplicateSettingKey !Text !FlowPackName !FlowPackName
  | DecisionProgramsRejected !DecisionFailure
  | ResultCodecsRejected !DecisionFailure
  deriving stock (Eq, Show)

renderFlowRegistryError :: FlowRegistryError -> Text
renderFlowRegistryError = \case
  DuplicatePackName pack -> "pack " <> flowPackNameText pack <> " is composed twice"
  DuplicateFlowName flow first second ->
    "flow " <> declarationCoordinateText flow <> " is contributed by both pack " <> flowPackNameText first <> " and pack " <> flowPackNameText second
  DuplicateTaskName task first second ->
    "program task " <> task <> " is contributed by both pack " <> flowPackNameText first <> " and pack " <> flowPackNameText second
  DuplicateSettingKey key first second ->
    "setting " <> key <> " is declared by both pack " <> flowPackNameText first <> " and pack " <> flowPackNameText second
  DecisionProgramsRejected failure -> "the composed decision programs were refused: " <> Text.pack (show failure)
  ResultCodecsRejected failure -> "the composed result codecs were refused: " <> Text.pack (show failure)

-- | Compose packs in the order given. Every error is reported, not only the
-- first, so one failed start names everything an operator must fix.
composeFlowRegistry :: [FlowPack] -> Either (NonEmpty FlowRegistryError) FlowRegistry
composeFlowRegistry composed =
  case NonEmpty.nonEmpty (packErrors <> flowErrors <> taskErrors <> settingErrors <> programErrors <> codecErrors) of
    Just errors -> Left errors
    Nothing -> case (programsResult, codecsResult) of
      (Right programs, Right codecs) -> Right FlowRegistry {packs = packNames, entries, taskEntries, programs, codecs}
      -- Both failures are already reported above; this arm is unreachable.
      _ -> Left (NonEmpty.fromList (programErrors <> codecErrors))
  where
    packNames = [pack.name | pack <- composed]
    entries = [RegisteredFlow {pack = pack.name, flow} | pack <- composed, flow <- pack.flows]
    taskEntries = [(pack.name, task) | pack <- composed, task <- pack.tasks]
    packErrors = [DuplicatePackName name | (name, _, _) <- repeated [(name, name) | name <- packNames]]
    flowErrors = [DuplicateFlowName name first second | (name, first, second) <- repeated [(entry.flow.definition.name, entry.pack) | entry <- entries]]
    taskErrors = [DuplicateTaskName name first second | (name, first, second) <- repeated [(taskName task, pack) | (pack, task) <- taskEntries]]
    settingErrors = [DuplicateSettingKey key first second | (key, first, second) <- repeated [(setting.key, pack.name) | pack <- composed, setting <- pack.settings]]
    programsResult = Decision.programRegistry (concatMap (.decisionPrograms) composed)
    codecsResult = Decision.resultCodecRegistry (concatMap (.retainedCodecs) composed)
    programErrors = either (pure . DecisionProgramsRejected) (const []) programsResult
    codecErrors = either (pure . ResultCodecsRejected) (const []) codecsResult

-- | Each key seen more than once, with the owner of its first occurrence and
-- the owner of the repeat.
repeated :: (Eq key) => [(key, owner)] -> [(key, owner, owner)]
repeated = go []
  where
    go _ [] = []
    go seen ((key, owner) : rest) = case lookup key seen of
      Just first -> (key, first, owner) : go seen rest
      Nothing -> go ((key, owner) : seen) rest

taskName :: ProgramTask -> Text
taskName ProgramTask {name} = name

registeredPacks :: FlowRegistry -> [FlowPackName]
registeredPacks registry = registry.packs

registeredFlows :: FlowRegistry -> [RegisteredFlow]
registeredFlows registry = registry.entries

-- | The name of every composed flow, in composition order. This is what an
-- agent manifest's @Behavior.Flow { name }@ must match.
registeredFlowNames :: FlowRegistry -> [DeclarationCoordinate "flow"]
registeredFlowNames registry = [entry.flow.definition.name | entry <- registry.entries]

lookupFlow :: FlowRegistry -> DeclarationCoordinate "flow" -> Maybe RegisteredFlow
lookupFlow registry requested = find (\entry -> entry.flow.definition.name == requested) registry.entries

lookupTask :: FlowRegistry -> Text -> Maybe ProgramTask
lookupTask registry requested = snd <$> find (\(_, task) -> taskName task == requested) registry.taskEntries

decisionProgramRegistry :: FlowRegistry -> ProgramRegistry
decisionProgramRegistry registry = registry.programs

resultCodecRegistry :: FlowRegistry -> ResultCodecRegistry
resultCodecRegistry registry = registry.codecs

-- | The decision services of a composition. Taking the registry makes a
-- production site that forgot to compose its packs visible in review.
decisionServices :: FlowRegistry -> ModelCatalog -> DecisionServices
decisionServices registry catalog =
  DecisionServices {catalog, programs = registry.programs, codecs = registry.codecs, providers = decisionProviders}

-- | Every declaration error in an agent's behavior that this composition can
-- decide without running it, in declaration order. An empty list means the
-- behavior is deployable.
--
-- A @Behavior.Flow { name }@ naming a flow no composed pack provides used to
-- surface only from inside a running workflow, which cost a failed agent run
-- per trigger instead of a refused deployment. The message names the flows
-- this executable actually has, so an operator running a stock role against a
-- pack's agent sees which distribution they needed.
flowDeclarationErrors :: FlowRegistry -> AgentDecl -> [Text]
flowDeclarationErrors registry declaration@AgentDecl {behavior} =
  case behavior of
    Flow {name = flowName} -> case lookupFlow registry flowName of
      Nothing ->
        [ "unknown flow "
            <> declarationCoordinateText flowName
            <> "; registered flows: "
            <> Text.intercalate ", " (map declarationCoordinateText (registeredFlowNames registry))
        ]
      Just entry -> slotErrors registry.programs declaration (flowDecisionSlotsFor declaration entry.flow.definition)
    _ -> []

-- | Compose at process start and refuse to start on failure (ADR-38). It logs
-- @flow.registry.composed@ with each pack and its flows, or
-- @flow.registry.rejected@ with every error, and then exits non-zero.
composeFlowRegistryOrExit :: Log.Logger -> Text -> [FlowPack] -> IO FlowRegistry
composeFlowRegistryOrExit logger role composed =
  case composeFlowRegistry composed of
    Right registry -> do
      Log.logInfo logger "flow.registry.composed" ["role" .= role, "packs" .= map (describe registry) registry.packs]
      pure registry
    Left errors -> do
      Log.logError logger "flow.registry.rejected" ["role" .= role, "errors" .= map renderFlowRegistryError (NonEmpty.toList errors)]
      exitFailure
  where
    describe registry pack =
      object
        [ "name" .= flowPackNameText pack,
          "flows" .= [declarationCoordinateText entry.flow.definition.name | entry <- registry.entries, entry.pack == pack]
        ]
