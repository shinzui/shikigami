{-# LANGUAGE TypeFamilies #-}

module Shikigami.Flow.Decision
  ( Decision,
    DecisionSite,
    decisionSite,
    adaptiveSite,
    DecisionAccounting (..),
    DecisionStep (..),
    decisionStep,
    decisionSlot,
    decisionStepNames,
    decide,
    decisionCatalog,
    validateDecisionRoute,
    refuseDecision,
    DecisionServices (..),
    builtinDecisionServices,
    decisionProviders,
    emptyDecisionServices,
    DecisionEnv (..),
    runDecision,
    runDecisionAdvisory,
    runDecisionAccepted,
    AcceptedDecisionHost (..),
    pinnedDecisionPolicy,
    runDecisionDisabled,
  )
where

import Baikai.Provider.Registry (ApiProvider)
import Control.Exception qualified as Exception
import Control.Monad (unless, when)
import Data.Aeson (FromJSON, Result (..), ToJSON, Value, fromJSON, object, toJSON, (.=))
import Data.IORef (atomicModifyIORef', newIORef)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Typeable (Typeable)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Exception (throwIO)
import GHC.Generics (Generic)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), currentRunGeneration, currentWorkflow, step)
import Keiro.Workflow qualified as Workflow
import Kiroku.Store.Effect (Store)
import Shikigami.Agent.Decl (AgentDecl)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Attestation.PolicyValue (mkCeiling)
import Shikigami.Attestation.Resolve (ResolvedProfile)
import Shikigami.Behavior.Error (TransientBehaviorFailure (..))
import Shikigami.Decision.Accounting (rootAccountedDecisionHooks)
import Shikigami.Decision.Contract
import Shikigami.Decision.Evidence
import Shikigami.Decision.ModelAlias (modelAliasFromNonEmpty)
import Shikigami.Decision.ModelCatalog
import Shikigami.Execution.Driver qualified as Accepted
import Shikigami.Execution.Executor (ExecutionRuntime)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Execution.Start qualified as Accepted
import Shikigami.Execution.Transcript (ExecutionError (ExecutionStorageUnavailable, ProjectionUnavailable))
import Shikigami.Flow.Routing (RoutingRuntime (..))
import Shikigami.Log.Correlation (runCorrelationId)
import Shikigami.Program.Decision
import Shikigami.Program.Decision.Registry (decisionCodecs, decisionPrograms)
import Shikigami.Program.DecisionRunner
import Shikigami.Program.Runtime (ProgramRuntime)
import Shikigami.Router.Catalog (CandidateCatalog)
import Shikigami.Router.Decision (RouteDecision, validateRouteDecision)
import Shikigami.Router.Declaration (RouterDeclarationView (policy), validateRouterDeclaration, validatedRouterDeclaration)

-- | A decision call site: the checked label of the slot a flow decides at.
--
-- It is a value a pack supplies, not a kernel enumeration, so a flow outside
-- the core can decide without the kernel knowing its name. The site names the
-- two journal steps of a decision, @decision-prepare-\<site\>@ and
-- @decision-result-\<site\>@, so it is a durable label: a pack's site starts
-- with the pack's name.
type DecisionSite = DecisionSlotLabel

-- | A site from a literal. A malformed literal is a programming error, found
-- the first time the module is loaded.
decisionSite :: Text -> DecisionSite
decisionSite = either (error . show) id . parseDecisionSlotLabel

-- | Who pays for a site's provider calls. A step states its answer, so a new
-- site cannot inherit one by accident.
data DecisionAccounting = UnaccountedCall | RootAccountedCall
  deriving stock (Eq, Show)

-- | One typed decision a flow may make: where, who pays, and which program.
data DecisionStep i o = DecisionStep
  { site :: !DecisionSite,
    accounting :: !DecisionAccounting,
    program :: !(DecisionProgramRef i o)
  }

decisionStep :: DecisionSite -> DecisionAccounting -> DecisionProgramRef i o -> DecisionStep i o
decisionStep = DecisionStep

decisionSlot :: DecisionStep i o -> [ModelAlias] -> DecisionSlot
decisionSlot step' models = DecisionSlot step'.site [descriptor step'.program] models

decisionStepNames :: DecisionSite -> (StepName, StepName)
decisionStepNames site =
  ( StepName ("decision-prepare-" <> decisionSlotLabelText site),
    StepName ("decision-result-" <> decisionSlotLabelText site)
  )

-- | The kernel's own site: the adaptive-delivery coordinator's decision. It is
-- the only site the accepted-work interpreter serves.
adaptiveSite :: DecisionSite
adaptiveSite = decisionSite "adapt"

data DecisionServices = DecisionServices
  { catalog :: !ModelCatalog,
    programs :: !ProgramRegistry,
    codecs :: !ResultCodecRegistry,
    providers :: ![ApiProvider]
  }
  deriving stock (Generic)

-- | The decision services of the builtin pack alone. Tests use it; a process
-- composes its packs and calls 'Shikigami.Flow.Pack.decisionServices'.
builtinDecisionServices :: ModelCatalog -> DecisionServices
builtinDecisionServices catalog = DecisionServices catalog decisionPrograms decisionCodecs decisionProviders

emptyDecisionServices :: DecisionServices
emptyDecisionServices = builtinDecisionServices (either (error . show) id (modelCatalog []))

data DecisionEnv = DecisionEnv
  { agent :: !AgentDecl,
    inventory :: ![DecisionSlot],
    services :: !DecisionServices,
    runtime :: !ProgramRuntime,
    profile :: !(Maybe ResolvedProfile),
    evidence :: !DecisionEvidenceStore,
    routing :: !RoutingRuntime,
    timeoutMicros :: !DecisionTimeout,
    -- | The run's enrolled resource root, for slots whose calls it must pay for.
    root :: !(Maybe ExecutionRootId),
    beforeStep :: !(StepName -> IO ()),
    afterStep :: !(StepName -> IO ())
  }

-- Admission is a trusted process seam; it cannot be supplied by a Flow payload.
data AcceptedDecisionHost = AcceptedDecisionHost
  { execution :: !ExecutionRuntime,
    identity :: !AgentIdentity,
    admit :: !(PreparedDecision -> IO Value -> IO (Either ExecutionError Accepted.ExecutionStart))
  }

data Decision :: Effect where
  PinnedDecisionPolicy :: Decision m DecisionPolicySnapshot
  Decide :: (Typeable i, Typeable o, ToJSON i, FromJSON i) => DecisionStep i o -> ModelAlias -> i -> Decision m o
  RefuseDecision :: DecisionFailure -> Decision m a
  DecisionCatalog :: DecisionSite -> Decision m CandidateCatalog
  ValidateDecisionRoute :: CandidateCatalog -> RouteDecision -> Decision m RouteDecision

type instance DispatchOf Decision = Dynamic

decide :: (Decision :> es, Typeable i, Typeable o, ToJSON i, FromJSON i) => DecisionStep i o -> ModelAlias -> i -> Eff es o
decide slot model input = send (Decide slot model input)

refuseDecision :: (Decision :> es) => DecisionFailure -> Eff es a
refuseDecision failure = send (RefuseDecision failure)

-- | The journaled candidate catalog a decision at this site may route among.
-- Its step is @decision-catalog-\<site\>@.
decisionCatalog :: (Decision :> es) => DecisionSite -> Eff es CandidateCatalog
decisionCatalog site = send (DecisionCatalog site)

-- | Hold a program's route proposal to the declaration's router policy and
-- the journaled catalog before it can influence delegation.
validateDecisionRoute :: (Decision :> es) => CandidateCatalog -> RouteDecision -> Eff es RouteDecision
validateDecisionRoute catalog decision = send (ValidateDecisionRoute catalog decision)

runDecisionDisabled :: Eff (Decision : es) a -> Eff es a
runDecisionDisabled = interpret (\_ _ -> throwIO (DecisionAbort (decisionFailure InvalidSlot "decision capability is unavailable for this workflow")))

pinnedDecisionPolicy :: (Decision :> es) => Eff es DecisionPolicySnapshot
pinnedDecisionPolicy = send PinnedDecisionPolicy

runDecision :: (Workflow :> es, Store :> es, IOE :> es) => DecisionEnv -> Eff (Decision : es) a -> Eff es a
runDecision env action = do
  pinned <- journal env (StepName "decision-policy") (pure (resolvePolicy env.services.programs env.inventory env.services.catalog env.agent env.profile))
  policy <- either (throwIO . DecisionAbort) pure pinned
  runDecisionUsing env Nothing policy action

-- | Advisory callers must be able to retain deterministic findings even when
-- model-policy resolution refuses. Keep the same pinned policy result, but
-- raise its typed refusal at the capability request so the Flow can handle it.
-- Required decision Flows retain 'runDecision' and its eager refusal semantics.
runDecisionAdvisory :: (Workflow :> es, Store :> es, IOE :> es) => DecisionEnv -> Eff (Decision : es) a -> Eff es a
runDecisionAdvisory env action = do
  pinned <- journal env (StepName "decision-policy") (pure (resolvePolicy env.services.programs env.inventory env.services.catalog env.agent env.profile))
  case pinned of
    Right policy -> runDecisionUsing env Nothing policy action
    Left refusal ->
      interpret
        ( \_ -> \case
            RefuseDecision failure -> throwIO (DecisionAbort failure)
            _ -> throwIO (DecisionAbort refusal)
        )
        action

-- | Only the new adaptive call site uses accepted work. Its caller carries the
-- original policy through generations; it cannot expand from live declarations.
runDecisionAccepted :: (Workflow :> es, Store :> es, IOE :> es) => DecisionEnv -> AcceptedDecisionHost -> DecisionPolicySnapshot -> Eff (Decision : es) a -> Eff es a
runDecisionAccepted env host policy = runDecisionUsing env (Just host) policy

runDecisionUsing :: (Workflow :> es, Store :> es, IOE :> es) => DecisionEnv -> Maybe AcceptedDecisionHost -> DecisionPolicySnapshot -> Eff (Decision : es) a -> Eff es a
runDecisionUsing env accepted policy action = do
  used <- liftIO (newIORef [])
  interpret
    ( \_ -> \case
        PinnedDecisionPolicy -> pure policy
        RefuseDecision failure -> throwIO (DecisionAbort failure)
        Decide DecisionStep {site = label, accounting, program = (_currentRef :: DecisionProgramRef i o)} alias input -> do
          when (maybe False (const (label /= adaptiveSite)) accepted) (throwIO (DecisionAbort (decisionFailure InvalidSlot "accepted interpreter requires the adaptive slot")))
          -- Before the prepare step: a run that cannot pay records nothing it would owe.
          when (accounting == RootAccountedCall && isNothing env.root) (throwIO (DecisionAbort (decisionFailure InvalidSlot "decision slot requires an enrolled resource root")))
          repeated <- liftIO (atomicModifyIORef' used (\labels -> (label : labels, label `elem` labels)))
          when repeated (throwIO (DecisionAbort (decisionFailure InvalidSlot "decision slot repeated within one generation")))
          let (prepareName, resultName) = decisionStepNames label
          preparedResult <- journal env prepareName do
            (_, nativeWorkflowId@(WorkflowId workflowId)) <- currentWorkflow
            generation <- currentRunGeneration
            pure do
              checkedGeneration <- either (Left . decisionFailure ContractMismatch) Right (parseDecisionGeneration (toInteger generation))
              slot <-
                maybe
                  (Left (decisionFailure InvalidSlot "decision slot is absent from pinned policy"))
                  Right
                  (find (\slot -> slot.label == label) policy.slots)
              unless (alias `elem` slot.models) (Left (decisionFailure ForbiddenModel "model alias is not allowed for this pinned slot"))
              selected <- maybe (Left (decisionFailure UnknownModel "pinned model alias is unavailable")) Right (find (\model -> model.alias == alias) policy.models)
              program <- case slot.programs of
                [program] -> Right program
                _ -> Left (decisionFailure ContractMismatch "decision slot must select one immutable program")
              ref <- (resolveProgramRef env.services.programs program :: Either DecisionFailure (DecisionProgramRef i o))
              registered <- lookupProgram env.services.programs ref
              checked <- validateInput registered input
              let identity =
                    decisionPreparationId
                      ( object
                          [ "workflow" .= workflowId,
                            "generation" .= generation,
                            "label" .= label,
                            "program" .= program,
                            "model" .= selected,
                            "input" .= toJSON checked,
                            "policy" .= policy.policy
                          ]
                      )
              Right (PreparedDecision identity (runCorrelationId workflowId) nativeWorkflowId checkedGeneration label program (toJSON checked) selected policy.policy)
          prepared <- either (throwIO . DecisionAbort) pure preparedResult
          outcome <- case accepted of
            Just host -> do
              submitted <- journal env (StepName "decision-submit-adapt") do
                value <-
                  liftIO
                    ( host.admit prepared do
                        registered <- either (Exception.throwIO . DecisionAbort) pure (lookupProgram env.services.programs =<< (resolveProgramRef env.services.programs prepared.program :: Either DecisionFailure (DecisionProgramRef i o)))
                        pure (registeredParameterState registered)
                    )
                case value of
                  Left ExecutionStorageUnavailable -> throwIO (TransientBehaviorFailure "typed decision acknowledgement unavailable")
                  Left ProjectionUnavailable -> throwIO (TransientBehaviorFailure "typed decision projection unavailable")
                  _ -> pure value
              start <- either (const (throwIO (DecisionAbort (decisionFailure EvidenceFailure "typed decision admission refused")))) pure submitted
              completed <- Accepted.requestExecution host.execution start
              journal env resultName do
                loaded <- liftIO (Accepted.readExecutionResult host.execution host.identity completed)
                value <- either (const (throwIO (DecisionAbort (decisionFailure EvidenceFailure "accepted typed decision result is unavailable")))) pure loaded
                case fromJSON value of
                  Success outcome -> pure outcome
                  Error _ -> throwIO (DecisionAbort (decisionFailure UnsupportedVersion "accepted typed decision outcome codec is unavailable"))
            Nothing -> journal env resultName do
              -- Only the action of an uncommitted result step may consult executables
              -- or credential bindings. A completed step never enters this branch.
              let pending :: Either DecisionFailure (DecisionProgramRef i o, i)
                  pending = do
                    ref <- resolveProgramRef env.services.programs prepared.program
                    storedInput <- case fromJSON prepared.input of
                      Success value -> Right value
                      Error _ -> Left (decisionFailure InvalidInput "pinned decision input codec is unavailable")
                    pure (ref, storedInput)
              (result, observations) <- case pending of
                Left refusal -> pure (Left refusal, [])
                Right (ref, storedInput) -> do
                  let decisionRuntime =
                        DecisionRuntime
                          { runtime = env.runtime,
                            programs = env.services.programs,
                            catalog = env.services.catalog,
                            profile = env.profile,
                            hooks = decisionCallHooks env.evidence env.profile,
                            providers = env.services.providers,
                            timeoutMicros = env.timeoutMicros,
                            callLimit = either (error . show) id (mkCeiling 64)
                          }
                  liftIO case (accounting, env.root) of
                    (RootAccountedCall, Just root) -> runDecisionProgramWithAccounting (rootAccountedDecisionHooks env.evidence env.profile root) decisionRuntime prepared ref storedInput
                    _ -> runDecisionProgramWithAnswers decisionRuntime prepared ref storedInput
              reportResult <- liftIO (readDecisionReport env.evidence prepared.runId)
              report <- either (throwIO . DecisionAbort) pure reportResult
              let calls = maybe [] (filter (\call -> call.invocationId == prepared.identity) . (\stored -> stored.calls)) report
              unless
                (all (\call -> call.terminal /= Nothing) calls)
                (throwIO (DecisionAbort (decisionFailure EvidenceFailure "decision has an unresolved provider expectation")))
              committed <- case result of
                Left refusal -> pure (Left refusal)
                Right output -> do
                  codec <- either (throwIO . DecisionAbort) pure (lookupResultCodec @o env.services.codecs prepared.program)
                  pure (Right (encodeResult codec output))
              pure (decisionOutcome prepared.identity prepared.program committed (map (\call -> call.callId) calls) observations)
          unless
            (outcome.preparationId == prepared.identity && outcome.program == prepared.program)
            (throwIO (DecisionAbort (decisionFailure ContractMismatch "decision outcome and preparation differ")))
          case outcome.result of
            Left refusal -> throwIO (DecisionAbort refusal)
            Right value -> do
              codec <- either (throwIO . DecisionAbort) pure (lookupResultCodec @o env.services.codecs outcome.program)
              either (throwIO . DecisionAbort) pure (decodeResult codec value)
        DecisionCatalog site -> do
          validated <- either (const (throwIO (DecisionAbort (decisionFailure InvalidSlot "decision router declaration is invalid")))) pure (validateRouterDeclaration env.agent)
          journal env (StepName ("decision-catalog-" <> decisionSlotLabelText site)) (liftIO (env.routing.resolveCatalog validated))
        ValidateDecisionRoute catalog decision -> do
          validated <- either (const (throwIO (DecisionAbort (decisionFailure InvalidSlot "decision router declaration is invalid")))) pure (validateRouterDeclaration env.agent)
          case validateRouteDecision (validatedRouterDeclaration validated).policy catalog decision of
            Left _ -> throwIO (DecisionAbort (decisionFailure OutputValidationFailure "decision route proposal is invalid"))
            Right _ -> pure decision
    )
    action

journal :: (Workflow :> es, IOE :> es, ToJSON a, FromJSON a) => DecisionEnv -> StepName -> Eff es a -> Eff es a
journal env name action = step name do
  liftIO (env.beforeStep name)
  result <- action
  liftIO (env.afterStep name)
  pure result
