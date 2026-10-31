module Shikigami.DecisionWorkflowSpec (tests) where

import Baikai.Content (AssistantContent (AssistantText), TextContent (..))
import Baikai.Evidence qualified as B
import Baikai.Model qualified as Model
import Baikai.Options qualified as Options
import Baikai.Provider.Registry (ApiProvider (..))
import Baikai.Response (Response (..))
import Baikai.Stream (liftCompleteToStream)
import Control.Exception (SomeException, try)
import Control.Monad (when)
import Data.Aeson (Value, encode, object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as AliasText
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TextIO
import Data.Time (UTCTime (..), fromGregorian)
import Data.Vector qualified as V
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Keiro.Outbox qualified as Outbox
import Keiro.Workflow (StepName (..), WorkflowId (..), WorkflowOutcome (..), WorkflowRunOptions (..), loadStepIndex, runWorkflowWith)
import Keiro.Workflow.Child.Schema (lookupChildrenOfParent)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), Priority (Normal), ProfileRequirement (..), RecipientFrom (SubjectOwner), RouterConfidence (RoutingHigh), SignalType (Reminder), Sink (..))
import Shikigami.Agent.Delegate (delegatedWorkflowIdV2)
import Shikigami.Agent.ExpertiseKey (ExpertiseKey, parseExpertiseKey)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Run (AgentRunResult (..))
import Shikigami.Agent.RunJob (RunJob (..), runJobWorkflowId)
import Shikigami.Agent.Workflow qualified as Agent
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.Attestation.Compliance (ComplianceRollUp (..))
import Shikigami.Attestation.Envelope (profileDigest)
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve (ResolvedProfile (..))
import Shikigami.Behavior.Provider.Coordinate qualified as Coordinate
import Shikigami.Behavior.Run (BehaviorEnv (..), newBehaviorEnv)
import Shikigami.Behavior.StubProvider (stubModel)
import Shikigami.Decision.Contract
import Shikigami.Decision.Evidence
import Shikigami.Decision.ModelAlias qualified as Alias
import Shikigami.Decision.ModelCatalog
import Shikigami.Decision.StubProvider (decisionStubProvider)
import Shikigami.Flow qualified as Flow
import Shikigami.Flow.Decision qualified as Decision
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Log.Correlation (runCorrelationId)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Prelude ((&), (.~))
import Shikigami.Program.Decision
import Shikigami.Program.Decision.Examples
import Shikigami.Program.DecisionRunner (DecisionRuntime (..), runDecisionProgram)
import Shikigami.Router.Catalog (CandidateCatalog (..))
import Shikigami.Router.Decision (RouteDecision (..), RouteOutcome (..), RouteSelection (..))
import Shikigami.RouterWorkflowSpec qualified as Fixture
import Shikigami.Sink (GrantSource (StaticGrants), SinkKind (SKizashiSignal))
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)
import Shikumi.Program (Program (FMap))
import System.Directory (doesFileExist)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

binding :: Text -> Text -> Text -> ModelBinding
binding alias version exact = mustRight (modelBinding (fixtureModelAlias alias) version alias "1" ((stubModel & #modelId .~ (exact))) Options.emptyOptions Nothing)

a, b, changedB :: ModelBinding
a = binding "triage" "1" "stub-triage"
b = binding "investigate" "1" "stub-investigate"
changedB = binding "investigate" "2" "stub-new-investigate"

catalog :: ModelCatalog
catalog = mustRight (modelCatalog [a, b])

declaration :: AgentDecl
declaration = (Fixture.routerDecl & #behavior .~ (Flow {name = "shikumi-decision-example"}) & #decisionModels .~ (map fixtureModelAlias ["triage", "investigate"]))

job :: Text -> RunJob
job key = (Fixture.routerJob key) {triggerPayload = object ["request" .= ("Investigate the architecture practice" :: Text)]}

scriptedProvider :: TriageAction -> InvestigationResult -> IO (ApiProvider, IO [Text])
scriptedProvider triageAction investigation = do
  seen <- newIORef []
  let complete model context options = do
        atomicModifyIORef' seen (\xs -> (xs <> [Model.modelId model], ()))
        response <- decisionStubProvider.complete model context options
        let reply = if Model.modelId model == "stub-triage" then toJSON (TriageResult triageAction "original triage facts" 0.82) else toJSON investigation
            evidence = (\ev -> (ev & #responseCommitment .~ (B.Observed (B.commitmentDigest reply)))) <$> response.evidence
        pure (response & #message . #content .~ V.singleton (AssistantText (TextContent (TE.decodeUtf8 (LBS.toStrict (encode reply))))) & #evidence .~ evidence)
  pure ((decisionStubProvider & #complete .~ (complete) & #stream .~ (liftCompleteToStream complete)), readIORef seen)

returned :: InvestigationResult
returned = InvestigationResult ReturnResult "original investigation" "" 0.91

withRuntime :: DatabaseFixture -> (AppEnv -> KirokuStore -> BehaviorEnv -> IO a) -> IO a
withRuntime fixture use = withShikigamiFreshDatabase fixture \connection ->
  withStore (defaultConnectionSettings connection) \store -> do
    tracer <- noopTracer
    behavior <- newBehaviorEnv
    use (AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing, store = Nothing}) store behavior

deps :: AppEnv -> KirokuStore -> BehaviorEnv -> ApiProvider -> Decision.DecisionServices -> Agent.AgentRunDeps
deps app store behavior handler services =
  (Fixture.routerDeps app behavior (Routing.RoutingRuntime (\_ -> pure Fixture.catalog) (\_ _ _ -> error "router evaluator must not run")) [declaration, Fixture.successSpecialist "first"])
    { Agent.decisions = (services & #providers .~ ([handler])),
      Agent.deliveryPool = Just store.pool
    }

crashAt :: Bool -> Text -> IO Agent.AgentRunHooks
crashAt after label = do
  once <- newIORef True
  let hook (StepName name) = when (name == label) do
        crash <- atomicModifyIORef' once (\current -> (False, current))
        when crash (ioError (userError "decision fixture crash"))
  pure (if after then (Agent.defaultAgentRunHooks & #afterStepBody .~ (hook)) else (Agent.defaultAgentRunHooks & #beforeStepBody .~ (hook)))

assertCompleted :: Either e (WorkflowOutcome (Either failure AgentRunResult)) -> IO Value
assertCompleted = \case
  Right (Completed (Right result)) -> pure result.behaviorOutput
  _ -> assertFailure "decision workflow did not complete successfully"

report :: KirokuStore -> Text -> IO DecisionEvidenceReport
report store key = do
  result <- readDecisionReport (postgresDecisionEvidenceStore store.pool) (runCorrelationId key)
  expectRight result >>= maybe (assertFailure "decision report missing") pure

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "durable typed decisions"
    [ testCase "the example executes three actual calls under two selected models" $
        withRuntime fixture \app store behavior -> do
          (handler, observed) <- scriptedProvider Investigate returned
          let runtime = deps app store behavior handler (Decision.defaultDecisionServices catalog)
              request = job "decision-three-calls"
          _ <- assertCompleted =<< Agent.runAgentRunWorkflow runtime request
          observed >>= (@?= ["stub-triage", "stub-investigate", "stub-investigate"])
          evidence <- report store "decision-three-calls"
          length evidence.calls @?= 3
          evidence.complete @?= True
          length evidence.invocations @?= 2
          index <- expectRight =<< runAppIO app (loadStepIndex Agent.agentRunWorkflowName (runJobWorkflowId request) 0)
          mapM_
            ( \(label, program, model, count) -> do
                preparation <- case Map.lookup ("decision-prepare-" <> label) index of
                  Just value -> case Aeson.fromJSON @(Either DecisionFailure PreparedDecision) value of
                    Aeson.Success (Right pinned) -> pure pinned
                    _ -> assertFailure "invalid prepared journal envelope"
                  Nothing -> assertFailure "missing preparation"
                preparation.workflowId @?= runJobWorkflowId request
                preparation.generation @?= initialDecisionGeneration
                decisionSlotLabelText preparation.label @?= label
                preparation.program @?= program
                preparation.model @?= model
                outcome <- case Map.lookup ("decision-result-" <> label) index of
                  Just value -> case Aeson.fromJSON @DecisionOutcome value of
                    Aeson.Success stored -> pure stored
                    _ -> assertFailure "invalid result journal envelope"
                  Nothing -> assertFailure "missing outcome"
                outcome.preparationId @?= preparation.identity
                outcome.program @?= program
                length outcome.attempts @?= count
            )
            [ ("triage", descriptor (programRef triageProgram), modelDescriptor a, 1),
              ("investigate", descriptor (programRef investigationProgram), modelDescriptor b, 2)
            ],
      testCase "ReturnNow makes no investigation call and creates no child" $
        withRuntime fixture \app store behavior -> do
          (handler, observed) <- scriptedProvider ReturnNow returned
          let runtime = deps app store behavior handler (Decision.defaultDecisionServices catalog)
              request = job "decision-return-now"
          _ <- assertCompleted =<< Agent.runAgentRunWorkflow runtime request
          observed >>= (@?= ["stub-triage"])
          children <- runAppIO app (lookupChildrenOfParent (runJobWorkflowId request).unWorkflowId "shikigami.agent-run")
          fmap length children @?= Right 0,
      testCase "completed decisions replay with removed executables, bindings and changed responses" $
        withRuntime fixture \app store behavior -> do
          (handler, observed) <- scriptedProvider Investigate returned
          hooks <- crashAt False "record"
          let withSink = (declaration & #sinks .~ ([KizashiSignal "shinzui/shikigami" Reminder Normal 50 SubjectOwner (Just "recipient") "decision complete" []]))
              runtime = (deps app store behavior handler (Decision.defaultDecisionServices catalog)) {Agent.hooks = hooks, Agent.agents = [withSink, Fixture.successSpecialist "first"], Agent.grants = StaticGrants (Map.singleton "router" (Set.singleton SKizashiSignal))}
              request = job "decision-completed-replay"
          first <- try @SomeException (Agent.runAgentRunWorkflow runtime request)
          assertBool "crashed after decision commits" (either (const True) (const False) first)
          observed >>= (@?= ["stub-triage", "stub-investigate", "stub-investigate"])
          (changed, changedCalls) <- scriptedProvider ReturnNow (returned & #summary .~ "changed provider output")
          let retained = (Decision.emptyDecisionServices & #programs .~ (mustRight (programRegistry [SomeProgram derivedInvestigation])))
              resumed = deps app store ((behavior & #model .~ ((stubModel & #modelId .~ ("changed-default"))))) changed retained
          output <- assertCompleted =<< Agent.runAgentRunWorkflow resumed request
          assertBool "original confidence and branch survive" ("original investigation" `Text.isInfixOf` Text.pack (show output) && "0.82" `Text.isInfixOf` Text.pack (show output))
          _ <- assertCompleted =<< Agent.runAgentRunWorkflow resumed request
          changedCalls >>= (@?= [])
          rows <- expectRight =<< runAppIO app (Outbox.listOutbox "shinzui/shikigami")
          length rows @?= 1,
      testCase "an unprepared second decision uses the pinned historical binding" $
        withRuntime fixture \app store behavior -> do
          (handler, observed) <- scriptedProvider Investigate returned
          hooks <- crashAt False "decision-catalog-investigate"
          let runtime = (deps app store behavior handler (Decision.defaultDecisionServices catalog)) {Agent.hooks = hooks}
              request = job "decision-pending-binding"
          _ <- try @SomeException (Agent.runAgentRunWorkflow runtime request)
          observed >>= (@?= ["stub-triage"])
          let changedCatalog = mustRight (retainModelBindings (mustRight (modelCatalog [a, changedB])) [b])
          _ <- assertCompleted =<< Agent.runAgentRunWorkflow (deps app store behavior handler (Decision.defaultDecisionServices changedCatalog)) request
          observed >>= (@?= ["stub-triage", "stub-investigate", "stub-investigate"]),
      testCase "an unavailable pinned binding refuses before dispatch" $
        withRuntime fixture \app store behavior -> do
          (handler, observed) <- scriptedProvider Investigate returned
          hooks <- crashAt False "decision-result-investigate"
          let runtime = (deps app store behavior handler (Decision.defaultDecisionServices catalog)) {Agent.hooks = hooks}
              request = job "decision-unavailable-binding"
          _ <- try @SomeException (Agent.runAgentRunWorkflow runtime request)
          let changedCatalog = mustRight (modelCatalog [a, changedB])
          result <- Agent.runAgentRunWorkflow (deps app store behavior handler (Decision.defaultDecisionServices changedCatalog)) request
          assertBool "bounded unavailable failure" (case result of Right (Completed (Left _)) -> True; _ -> False)
          observed >>= (@?= ["stub-triage"])
          evidence <- report store "decision-unavailable-binding"
          length evidence.calls @?= 1,
      testCase "a lost result append retains both actual investigation attempts" $
        withRuntime fixture \app store behavior -> do
          (handler, observed) <- scriptedProvider Investigate returned
          hooks <- crashAt True "decision-result-investigate"
          let runtime = (deps app store behavior handler (Decision.defaultDecisionServices catalog)) {Agent.hooks = hooks}
              request = job "decision-lost-append"
          _ <- try @SomeException (Agent.runAgentRunWorkflow runtime request)
          observed >>= (\calls -> length calls @?= 3)
          _ <- assertCompleted =<< Agent.runAgentRunWorkflow runtime request
          observed >>= (\calls -> length calls @?= 5)
          evidence <- report store "decision-lost-append"
          length evidence.calls @?= 5
          evidence.complete @?= True,
      testCase "a two-model profile admits selected models while the unused default is forbidden" $
        withRuntime fixture \app store behavior -> do
          (handler, observed) <- scriptedProvider Investigate returned
          let policy = profileFor ["stub-triage", "stub-investigate"]
              declared = (declaration & #sanctionedProfile .~ (Just (ProfileRequirement "decision-profile" (Just "1"))))
              runtime =
                (deps app store behavior handler (Decision.defaultDecisionServices catalog))
                  { Agent.agents = [declared],
                    Agent.resolveRunProfile = \_ _ -> pure (Right policy)
                  }
          _ <- assertCompleted =<< Agent.runAgentRunWorkflow runtime (job "decision-profile-both")
          observed >>= (\calls -> length calls @?= 3)
          evidence <- report store "decision-profile-both"
          assertBool "all actual calls assessed" (case evidence.assessment of Just assessment -> assessment.sanctioned && length assessment.accountedCalls == 3; _ -> False),
      testCase "a one-model profile rejects the unpermitted slot before any provider dispatch" $
        withRuntime fixture \app store behavior -> do
          (handler, observed) <- scriptedProvider Investigate returned
          let policy = profileFor ["stub-triage"]
              declared = (declaration & #sanctionedProfile .~ (Just (ProfileRequirement "decision-profile" (Just "1"))))
              runtime =
                (deps app store behavior handler (Decision.defaultDecisionServices catalog))
                  { Agent.agents = [declared],
                    Agent.resolveRunProfile = \_ _ -> pure (Right policy)
                  }
          outcome <- Agent.runAgentRunWorkflow runtime (job "decision-profile-one")
          assertBool "bounded policy refusal" (case outcome of Right (Completed (Left _)) -> True; _ -> False)
          observed >>= (@?= []),
      testCase "existing routing flows still refuse their forbidden default model" $
        withRuntime fixture \app store behavior -> do
          (handler, observed) <- scriptedProvider Investigate returned
          let policy = profileFor ["stub-triage", "stub-investigate"]
              declared = (Fixture.routerDecl & #sanctionedProfile .~ (Just (ProfileRequirement "decision-profile" (Just "1"))))
              runtime =
                (deps app store behavior handler (Decision.defaultDecisionServices catalog))
                  { Agent.agents = [declared],
                    Agent.resolveRunProfile = \_ _ -> pure (Right policy)
                  }
          outcome <- Agent.runAgentRunWorkflow runtime (job "decision-router-default")
          assertBool "default still refused" (case outcome of Right (Completed (Left _)) -> True; _ -> False)
          observed >>= (@?= []),
      testCase "domain-invalid output cannot reach investigation or delegation" $
        withRuntime fixture \app store behavior -> do
          (base, observed) <- scriptedProvider Investigate returned
          let complete model context options = do
                response <- base.complete model context options
                let invalid = toJSON (TriageResult Investigate "invalid confidence" 2.0)
                pure (response & #message . #content .~ V.singleton (AssistantText (TextContent (TE.decodeUtf8 (LBS.toStrict (encode invalid))))))
              handler = (base & #complete .~ (complete) & #stream .~ (liftCompleteToStream complete))
              runtime = deps app store behavior handler (Decision.defaultDecisionServices catalog)
              request = job "decision-invalid-output"
          outcome <- Agent.runAgentRunWorkflow runtime request
          assertBool "bounded invalid output failure" (case outcome of Right (Completed (Left _)) -> True; _ -> False)
          observed >>= (@?= ["stub-triage"])
          children <- runAppIO app (lookupChildrenOfParent (runJobWorkflowId request).unWorkflowId "shikigami.agent-run")
          fmap length children @?= Right 0,
      testCase "every compiled slot maps to its exact declared prepare and result labels" do
        atRoot <- doesFileExist "domain/shikigami/agent-run.keiro"
        declared <- TextIO.readFile (if atRoot then "domain/shikigami/agent-run.keiro" else "../domain/shikigami/agent-run.keiro")
        let compiled = [slot.label | flow <- Flow.flowRegistry, slot <- flow.decisionSlots]
        compiled @?= [triageDecisionSlot, investigationDecisionSlot]
        mapM_
          ( \label -> do
              let (StepName prepare, StepName result) = Decision.decisionStepNames label
              assertBool "prepare declared" (("step " <> prepare) `Text.isInfixOf` declared)
              assertBool "result declared" (("step " <> result) `Text.isInfixOf` declared)
          )
          [Decision.Triage, Decision.Investigation],
      testCase "local derivation changes neither an old committed result nor a pinned pending state" $
        withRuntime fixture \app store behavior -> do
          (handler, observed) <- scriptedProvider Investigate returned
          hooks <- crashAt False "decision-catalog-investigate"
          let runtime = (deps app store behavior handler (Decision.defaultDecisionServices catalog)) {Agent.hooks = hooks}
              request = job "decision-local-derivation"
          _ <- try @SomeException (Agent.runAgentRunWorkflow runtime request)
          let programs = mustRight (programRegistry [SomeProgram triageProgram, SomeProgram investigationProgram, SomeProgram derivedInvestigation])
              codecs = mustRight (resultCodecRegistry [retainedCodec triageProgram, retainedCodec investigationProgram, retainedCodec derivedInvestigation])
              services = (Decision.defaultDecisionServices catalog) {Decision.programs = programs, Decision.codecs = codecs}
          output <- assertCompleted =<< Agent.runAgentRunWorkflow (deps app store behavior handler services) request
          assertBool "pending state retains original full result" ("original investigation" `Text.isInfixOf` Text.pack (show output) && "0.91" `Text.isInfixOf` Text.pack (show output))
          observed >>= (\calls -> length calls @?= 3)
          -- Qualify the alternative on the actual Handan path with identical
          -- input and provider response. Only pure postprocessing differs.
          (comparison, _) <- scriptedProvider Investigate returned
          contexts <- newIORef []
          let capture model context options = do
                atomicModifyIORef' contexts (\xs -> (xs <> [show context], ()))
                comparison.complete model context options
              captured = (comparison & #complete .~ (capture) & #stream .~ (liftCompleteToStream capture))
              input = InvestigationInput "Investigate the architecture practice" "original triage facts" (TE.decodeUtf8 (LBS.toStrict (encode Fixture.catalog)))
              prepare registered = PreparedDecision (decisionPreparationId (Aeson.String "compare")) (runCorrelationId "compare") (WorkflowId "compare") initialDecisionGeneration investigationDecisionSlot (descriptor (programRef registered)) (toJSON input) (modelDescriptor b) Nothing
          (callHooks, _) <- newMemoryCallHooks
          let runner = DecisionRuntime behavior.runtime programs catalog Nothing callHooks [captured] 2_000_000 64
          old <- runDecisionProgram runner (prepare investigationProgram) (programRef investigationProgram) input
          new <- runDecisionProgram runner (prepare derivedInvestigation) (programRef derivedInvestigation) input
          old @?= Right returned
          new @?= Right (returned & #summary .~ "new local derivation" & #confidence .~ 0.11)
          sent <- readIORef contexts
          take 2 sent @?= drop 2 sent,
      testCase "removing the pinned local derivation refuses a pending invocation" $
        withRuntime fixture \app store behavior -> do
          (handler, observed) <- scriptedProvider Investigate returned
          hooks <- crashAt False "decision-result-investigate"
          let runtime = (deps app store behavior handler (Decision.defaultDecisionServices catalog)) {Agent.hooks = hooks}
              request = job "decision-missing-state"
          _ <- try @SomeException (Agent.runAgentRunWorkflow runtime request)
          let services = (Decision.defaultDecisionServices catalog) {Decision.programs = mustRight (programRegistry [SomeProgram triageProgram, SomeProgram derivedInvestigation])}
          outcome <- Agent.runAgentRunWorkflow (deps app store behavior handler services) request
          assertBool "unavailable pinned state is bounded" (case outcome of Right (Completed (Left _)) -> True; _ -> False)
          observed >>= (@?= ["stub-triage"]),
      testCase "evidence persistence failure cannot commit a successful decision result" $
        withRuntime fixture \app store behavior -> do
          (handler, observed) <- scriptedProvider Investigate returned
          _ <- expectRight =<< Pool.use store.pool (Session.script "CREATE FUNCTION shikigami.reject_workflow_terminal() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RAISE EXCEPTION ''fixture terminal fault''; END'; CREATE TRIGGER reject_workflow_terminal BEFORE UPDATE ON shikigami.decision_attempts FOR EACH ROW EXECUTE FUNCTION shikigami.reject_workflow_terminal();")
          let runtime = deps app store behavior handler (Decision.defaultDecisionServices catalog)
              request = job "decision-evidence-failure"
          outcome <- Agent.runAgentRunWorkflow runtime request
          assertBool "bounded evidence failure" (case outcome of Right (Completed (Left _)) -> True; _ -> False)
          observed >>= (@?= ["stub-triage"])
          evidence <- report store "decision-evidence-failure"
          evidence.complete @?= False
          index <- expectRight =<< runAppIO app (loadStepIndex Agent.agentRunWorkflowName (runJobWorkflowId request) 0)
          case Map.lookup "decision-result-triage" index of
            Nothing -> pure ()
            Just value -> case Aeson.fromJSON @DecisionOutcome value of
              Aeson.Success result -> assertBool "no successful result envelope" (case result.result of Left _ -> True; Right _ -> False)
              Aeson.Error _ -> assertFailure "unexpected result envelope",
      testCase "no-match, ambiguous and invalid proposals create no children" $
        mapM_
          ( \(key, route, succeeds) -> withRuntime fixture \app store behavior -> do
              let investigation = InvestigationResult ProposeRoute "route proposal" (TE.decodeUtf8 (LBS.toStrict (encode route))) 0.9
              (handler, observed) <- scriptedProvider Investigate investigation
              let request = job key
              outcome <- Agent.runAgentRunWorkflow (deps app store behavior handler (Decision.defaultDecisionServices catalog)) request
              if succeeds
                then do _ <- assertCompleted outcome; pure ()
                else assertBool "invalid route fails" (case outcome of Right (Completed (Left _)) -> True; _ -> False)
              observed >>= (\calls -> length calls @?= 3)
              children <- expectRight =<< runAppIO app (lookupChildrenOfParent (runJobWorkflowId request).unWorkflowId "shikigami.agent-run")
              length children @?= 0
          )
          [ ("decision-no-match", RouteDecision 1 Fixture.catalog.version (NoMatch "none"), True),
            ("decision-ambiguous", RouteDecision 1 Fixture.catalog.version (Ambiguous (RouteSelection (fixtureAgentName "first") [(fixtureExpertiseKey "observability")] RoutingHigh "possible" :| []) "unclear"), True),
            ("decision-invalid-route", RouteDecision 1 Fixture.catalog.version (Matched (RouteSelection (fixtureAgentName "forged-agent") [(fixtureExpertiseKey "observability")] RoutingHigh "forged" :| [])), False)
          ],
      testCase "a valid investigation route crosses governed delegation once" $
        withRuntime fixture \app store behavior -> do
          let route = RouteDecision 1 Fixture.catalog.version (Matched (RouteSelection (fixtureAgentName "first") [(fixtureExpertiseKey "observability")] RoutingHigh "specialist" :| []))
              investigation = InvestigationResult ProposeRoute "delegate safely" (TE.decodeUtf8 (LBS.toStrict (encode route))) 0.9
          (handler, observed) <- scriptedProvider Investigate investigation
          let runtime = deps app store behavior handler (Decision.defaultDecisionServices catalog)
              request = job "decision-delegate"
          parked <- Agent.runAgentRunWorkflow runtime request
          case parked of Right Suspended -> pure (); _ -> assertFailure "expected governed child suspension"
          let childId = delegatedWorkflowIdV2 (runJobWorkflowId request) (fixtureAgentName "first") "decision-investigate-first"
          _ <- Fixture.runSuccessfulChild app runtime childId
          _ <- assertCompleted =<< Agent.runAgentRunWorkflow runtime request
          observed >>= (\calls -> length calls @?= 3)
          children <- runAppIO app (lookupChildrenOfParent (runJobWorkflowId request).unWorkflowId "shikigami.agent-run")
          fmap length children @?= Right 1
    ]

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (assertFailure . show) pure

mustRight :: (Show e) => Either e a -> a
mustRight = either (error . show) id

profileFor :: [Text] -> ResolvedProfile
profileFor models = ResolvedProfile content (Profile.SanctionedExecutionProfileRef (Profile.ProfileId "decision-profile") (Profile.ProfileVersion "1") (profileDigest content))
  where
    allowed = [Profile.AllowedCall (Coordinate.providerCoordinate "stub") (Coordinate.providerCoordinate "stub") (Coordinate.providerCoordinate "in-process") (Coordinate.providerCoordinate model) Profile.ThinkingHigh | model <- models]
    content =
      Profile.SanctionedExecutionProfile
        { profileId = Profile.ProfileId "decision-profile",
          version = Profile.ProfileVersion "1",
          issuer = Profile.Issuer "fixture",
          lifecycle = Profile.Active,
          validFrom = UTCTime (fromGregorian 2026 1 1) 0,
          validUntil = Nothing,
          allowedCalls = case allowed of x : xs -> x :| xs; [] -> error "profile needs an allowed model",
          prohibitions = (Profile.defaultProhibitions & #defaultedThinkingAllowed .~ (True)),
          limits = Profile.unlimitedProfileLimits,
          minimumEvidenceStrength = Profile.EvidenceRequestedOnly,
          requiredCorrelationFields = [],
          signerRequirements = Profile.noSignerRequirements
        }

derivedInvestigation :: RegisteredProgram InvestigationInput InvestigationResult
derivedInvestigation =
  mustRight
    ( registerProgram
        "request-investigation"
        "2"
        "sha256:local-derivation-v2"
        "investigation-input/1"
        "investigation-result/1"
        "investigation-validator/1"
        "investigation-derivation/2"
        (object ["threshold" .= (0.95 :: Double)])
        (FMap (\result -> result & #summary .~ "new local derivation" & #confidence .~ 0.11) (executable investigationProgram))
        jsonResultCodec
        Right
        Right
    )

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

fixtureExpertiseKey :: Text -> ExpertiseKey
fixtureExpertiseKey = either (error . show) id . parseExpertiseKey

fixtureModelAlias :: AliasText.Text -> Alias.ModelAlias
fixtureModelAlias = either (error . show) id . Alias.parseModelAlias
