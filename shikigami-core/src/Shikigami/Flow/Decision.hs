{-# LANGUAGE TypeFamilies #-}

module Shikigami.Flow.Decision
  ( Decision,
    DecisionLabel (..),
    DecisionStep,
    decisionStep,
    decisionSlot,
    decisionStepNames,
    decide,
    investigationCatalog,
    validateInvestigationRoute,
    refuseDecision,
    DecisionServices (..),
    defaultDecisionServices,
    emptyDecisionServices,
    DecisionEnv (..),
    runDecision,
    runDecisionDisabled,
  )
where

import Baikai.Provider.Registry (ApiProvider)
import Control.Monad (unless, when)
import Data.Aeson (FromJSON, Result (..), ToJSON, fromJSON, object, toJSON, (.=))
import Data.IORef (atomicModifyIORef', newIORef)
import Data.List (find)
import Data.Text (Text)
import Data.Typeable (Typeable)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Exception (throwIO)
import Handan.Runtime (Runtime)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), currentRunGeneration, currentWorkflow, step)
import Shikigami.Agent.Decl (AgentDecl)
import Shikigami.Attestation.Resolve (ResolvedProfile)
import Shikigami.Decision.Contract
import Shikigami.Decision.Evidence
import Shikigami.Decision.ModelCatalog
import Shikigami.Flow.Routing (RoutingRuntime (..))
import Shikigami.Log.Correlation (runCorrelationId)
import Shikigami.Program.Decision
import Shikigami.Program.Decision.Examples (exampleCodecs, examplePrograms)
import Shikigami.Program.DecisionRunner
import Shikigami.Router.Catalog (CandidateCatalog)
import Shikigami.Router.Decision (RouteDecision, validateRouteDecision)
import Shikigami.Router.Declaration (ValidatedRouterDeclaration (..), validateRouterDeclaration)

data DecisionLabel = Triage | Investigation
  deriving stock (Eq, Ord, Show)

data DecisionStep i o = DecisionStep !DecisionLabel !(DecisionProgramRef i o)

decisionStep :: DecisionLabel -> DecisionProgramRef i o -> DecisionStep i o
decisionStep = DecisionStep

decisionSlot :: DecisionStep i o -> [ModelAlias] -> DecisionSlot
decisionSlot (DecisionStep label ref) models = DecisionSlot (labelText label) [descriptor ref] models

labelText :: DecisionLabel -> Text
labelText Triage = "triage"
labelText Investigation = "investigate"

decisionStepNames :: DecisionLabel -> (StepName, StepName)
decisionStepNames Triage = (StepName "decision-prepare-triage", StepName "decision-result-triage")
decisionStepNames Investigation = (StepName "decision-prepare-investigate", StepName "decision-result-investigate")

data DecisionServices = DecisionServices
  { catalog :: !ModelCatalog,
    programs :: !ProgramRegistry,
    codecs :: !ResultCodecRegistry,
    providers :: ![ApiProvider]
  }

defaultDecisionServices :: ModelCatalog -> DecisionServices
defaultDecisionServices catalog = DecisionServices catalog examplePrograms exampleCodecs decisionProviders

emptyDecisionServices :: DecisionServices
emptyDecisionServices = defaultDecisionServices (either (error . show) id (modelCatalog []))

data DecisionEnv = DecisionEnv
  { agent :: !AgentDecl,
    inventory :: ![DecisionSlot],
    services :: !DecisionServices,
    runtime :: !Runtime,
    profile :: !(Maybe ResolvedProfile),
    evidence :: !DecisionEvidenceStore,
    routing :: !RoutingRuntime,
    timeoutMicros :: !Int,
    beforeStep :: !(StepName -> IO ()),
    afterStep :: !(StepName -> IO ())
  }

data Decision :: Effect where
  Decide :: (Typeable i, Typeable o, ToJSON i, FromJSON i) => DecisionStep i o -> ModelAlias -> i -> Decision m o
  RefuseDecision :: DecisionFailure -> Decision m a
  InvestigationCatalog :: Decision m CandidateCatalog
  ValidateInvestigationRoute :: CandidateCatalog -> RouteDecision -> Decision m RouteDecision

type instance DispatchOf Decision = Dynamic

decide :: (Decision :> es, Typeable i, Typeable o, ToJSON i, FromJSON i) => DecisionStep i o -> ModelAlias -> i -> Eff es o
decide slot model input = send (Decide slot model input)

refuseDecision :: (Decision :> es) => DecisionFailure -> Eff es a
refuseDecision failure = send (RefuseDecision failure)

investigationCatalog :: (Decision :> es) => Eff es CandidateCatalog
investigationCatalog = send InvestigationCatalog

validateInvestigationRoute :: (Decision :> es) => CandidateCatalog -> RouteDecision -> Eff es RouteDecision
validateInvestigationRoute catalog decision = send (ValidateInvestigationRoute catalog decision)

runDecisionDisabled :: Eff (Decision : es) a -> Eff es a
runDecisionDisabled = interpret (\_ _ -> throwIO (DecisionAbort (decisionFailure InvalidSlot "decision capability is unavailable for this workflow")))

runDecision :: (Workflow :> es, IOE :> es) => DecisionEnv -> Eff (Decision : es) a -> Eff es a
runDecision env action = do
  pinned <- journal env (StepName "decision-policy") (pure (resolvePolicy env.services.programs env.inventory env.services.catalog env.agent env.profile))
  policy <- either (throwIO . DecisionAbort) pure pinned
  used <- liftIO (newIORef [])
  interpret
    ( \_ -> \case
        RefuseDecision failure -> throwIO (DecisionAbort failure)
        Decide (DecisionStep label (_currentRef :: DecisionProgramRef i o)) alias input -> do
          repeated <- liftIO (atomicModifyIORef' used (\labels -> (label : labels, label `elem` labels)))
          when repeated (throwIO (DecisionAbort (decisionFailure InvalidSlot "decision slot repeated within one generation")))
          let (prepareName, resultName) = decisionStepNames label
          preparedResult <- journal env prepareName do
            (_, WorkflowId workflowId) <- currentWorkflow
            generation <- currentRunGeneration
            pure do
              slot <-
                maybe
                  (Left (decisionFailure InvalidSlot "decision slot is absent from pinned policy"))
                  Right
                  (find (\slot -> slot.label == labelText label) policy.slots)
              unless (alias `elem` slot.models) (Left (decisionFailure ForbiddenModel "model alias is not allowed for this pinned slot"))
              selected <- maybe (Left (decisionFailure UnknownModel "pinned model alias is unavailable")) Right (find (\model -> model.alias == alias) policy.models)
              program <- case slot.programs of
                [program] -> Right program
                _ -> Left (decisionFailure ContractMismatch "decision slot must select one immutable program")
              ref <- (resolveProgramRef env.services.programs program :: Either DecisionFailure (DecisionProgramRef i o))
              registered <- lookupProgram env.services.programs ref
              checked <- validateInput registered input
              let identity =
                    versionedDigest
                      "shikigami.prepared-decision/1"
                      ( object
                          [ "workflow" .= workflowId,
                            "generation" .= generation,
                            "label" .= labelText label,
                            "program" .= program,
                            "model" .= selected,
                            "input" .= toJSON checked,
                            "policy" .= policy.policy
                          ]
                      )
              Right (PreparedDecision identity (runCorrelationId workflowId) workflowId (fromIntegral generation) (labelText label) program (toJSON checked) selected policy.policy)
          prepared <- either (throwIO . DecisionAbort) pure preparedResult
          outcome <- journal env resultName do
            -- Only the action of an uncommitted result step may consult executables
            -- or credential bindings. A completed step never enters this branch.
            let pending :: Either DecisionFailure (DecisionProgramRef i o, i)
                pending = do
                  ref <- resolveProgramRef env.services.programs prepared.program
                  storedInput <- case fromJSON prepared.input of
                    Success value -> Right value
                    Error _ -> Left (decisionFailure InvalidInput "pinned decision input codec is unavailable")
                  pure (ref, storedInput)
            result <- case pending of
              Left refusal -> pure (Left refusal)
              Right (ref, storedInput) ->
                liftIO
                  ( runDecisionProgram
                      DecisionRuntime
                        { runtime = env.runtime,
                          programs = env.services.programs,
                          catalog = env.services.catalog,
                          profile = env.profile,
                          hooks = decisionCallHooks env.evidence env.profile,
                          providers = env.services.providers,
                          timeoutMicros = env.timeoutMicros,
                          callLimit = 64
                        }
                      prepared
                      ref
                      storedInput
                  )
            case result of
              Left refusal -> pure (DecisionOutcome prepared.identity prepared.program (Left refusal) [])
              Right output -> do
                codec <- either (throwIO . DecisionAbort) pure (lookupResultCodec @o env.services.codecs prepared.program)
                reportResult <- liftIO (readDecisionReport env.evidence prepared.runId)
                report <- either (throwIO . DecisionAbort) pure reportResult
                let calls = maybe [] (filter (\call -> call.invocationId == prepared.identity) . (\stored -> stored.calls)) report
                unless
                  (all (\call -> call.terminal /= Nothing) calls)
                  (throwIO (DecisionAbort (decisionFailure EvidenceFailure "decision has an unresolved provider expectation")))
                pure (DecisionOutcome prepared.identity prepared.program (Right (encodeResult codec output)) (map (\call -> call.callId) calls))
          unless
            (outcome.preparationId == prepared.identity && outcome.program == prepared.program)
            (throwIO (DecisionAbort (decisionFailure ContractMismatch "decision outcome and preparation differ")))
          case outcome.result of
            Left refusal -> throwIO (DecisionAbort refusal)
            Right value -> do
              codec <- either (throwIO . DecisionAbort) pure (lookupResultCodec @o env.services.codecs outcome.program)
              either (throwIO . DecisionAbort) pure (decodeResult codec value)
        InvestigationCatalog -> do
          validated <- either (const (throwIO (DecisionAbort (decisionFailure InvalidSlot "decision router declaration is invalid")))) pure (validateRouterDeclaration env.agent)
          journal env (StepName "decision-catalog-investigate") (liftIO (env.routing.resolveCatalog validated))
        ValidateInvestigationRoute catalog decision -> do
          validated <- either (const (throwIO (DecisionAbort (decisionFailure InvalidSlot "decision router declaration is invalid")))) pure (validateRouterDeclaration env.agent)
          case validateRouteDecision validated.policy catalog decision of
            Left _ -> throwIO (DecisionAbort (decisionFailure OutputValidationFailure "investigation route proposal is invalid"))
            Right _ -> pure decision
    )
    action

journal :: (Workflow :> es, IOE :> es, ToJSON a, FromJSON a) => DecisionEnv -> StepName -> Eff es a -> Eff es a
journal env name action = step name do
  liftIO (env.beforeStep name)
  result <- action
  liftIO (env.afterStep name)
  pure result
