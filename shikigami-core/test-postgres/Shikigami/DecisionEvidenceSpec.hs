{-# LANGUAGE DataKinds #-}

module Shikigami.DecisionEvidenceSpec (tests) where

import Baikai.Evidence qualified as B
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Lens ((&), (.~))
import Control.Monad (forM_)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as AliasText
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as Sessions
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Attestation.Compliance (ComplianceDecision (..), ComplianceRollUp (..), evaluateCallFacts)
import Shikigami.Attestation.Evidence (CallRelationship (RootCall), ExpectedCall (..), providerAttempt)
import Shikigami.Attestation.PolicyValue qualified as PV
import Shikigami.Attestation.Profile qualified as P
import Shikigami.Attestation.Resolve (ResolvedProfile, ResolvedProfileView (..), resolvedProfileFor, resolvedProfileView)
import Shikigami.Behavior.Provider.Coordinate qualified as Coordinate
import Shikigami.Decision.Contract
import Shikigami.Decision.Contract qualified as Model
import Shikigami.Decision.Evidence
import Shikigami.Decision.ModelAlias qualified as Alias
import Shikigami.Log.Correlation (callCorrelationId, runCorrelationId)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

program :: ProgramDescriptor
program = ProgramDescriptor (identity "fixture") (identity "1") (identity "sha256:implementation") (identity "input/1") (identity "result/1") (identity "validator/1") ParametersV1 (programParameterDigest (String "fixture")) (identity "derive/1")
  where
    identity = mustRight . parseProgramIdentity

model :: ModelDescriptor
model = ModelDescriptor (fixtureModelAlias "triage") (fixtureModelRegistration "1") (modelDescriptorDigest (toJSON ("model" :: Text))) (Coordinate.providerCoordinate "stub") (Coordinate.providerCoordinate "stub") (Coordinate.providerCoordinate "in-process") (Coordinate.providerCoordinate "model-a") Nothing (fixtureModelRegistration "binding") (fixtureModelRegistration "1")

prepared :: PreparedDecision
prepared =
  PreparedDecision
    (decisionPreparationId (String "invocation-a"))
    (runCorrelationId "run-evidence")
    (WorkflowId "workflow-evidence")
    initialDecisionGeneration
    triageDecisionSlot
    program
    (object ["private-input" .= ("PROMPT_MARKER" :: Text)])
    model
    Nothing

context :: DecisionCallContext
context = DecisionCallContext prepared model

terminal :: Text -> B.ModelCallEvidence
terminal identifier =
  B.baseEvidence
    (B.evidenceRequest "run-evidence")
    identifier
    (B.EndpointIdentity "stub" "stub" B.TransportAgentRun Nothing "0.7.2.0" (Just "fixture/1"))
    "model-a"
    B.noThinkingRequested
    epoch
    epoch
    B.CallSucceeded
    "sha256:request"
    "sha256:configuration"

epoch :: UTCTime
epoch = UTCTime (fromGregorian 2026 1 1) 0

profile :: P.ProfileLimits -> ResolvedProfile
profile limits = resolvedProfileFor content
  where
    content =
      P.SanctionedExecutionProfile
        { profileId = P.ProfileId "test",
          version = P.ProfileVersion "1",
          issuer = P.Issuer "test",
          lifecycle = P.Active,
          validFrom = epoch,
          validUntil = Nothing,
          allowedCalls = P.AllowedCall (Coordinate.providerCoordinate "stub") (Coordinate.providerCoordinate "stub") (Coordinate.providerCoordinate "in-process") (Coordinate.providerCoordinate "model-a") P.ThinkingHigh :| [],
          prohibitions = (P.defaultProhibitions & #defaultedThinkingAllowed .~ (PV.Permitted)),
          limits,
          minimumEvidenceStrength = P.EvidenceRequestedOnly,
          requiredCorrelationFields = [],
          signerRequirements = P.noSignerRequirements
        }

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "durable decision evidence"
    [ testGroup "owned metadata refusals" [testCase name (metadataRefusal fixture pinned mutation) | (name, pinned, mutation) <- metadataCases],
      testCase "absence and SQL failure keep separate outcomes" $
        withShikigamiFreshDatabase fixture \connection -> withPool connection \pool -> do
          let store = postgresDecisionEvidenceStore pool
          readDecisionReport store (runCorrelationId "missing") >>= (@?= Right Nothing)
          listDecisionCalls store (runCorrelationId "missing") 0 20 >>= (@?= Right [])
          token <- expectRight =<< (decisionCallHooks store Nothing).beginCall context
          positive <- expectReport =<< readDecisionReport store prepared.runId
          map (\call -> call.callId) positive.calls @?= [attemptId token]
          sql pool "ALTER TABLE shikigami.decision_attempts RENAME TO audit_held_attempts"
          unavailable <- readDecisionReport store prepared.runId
          either (Right . failureCode) (const (Left ())) unavailable @?= Right EvidenceFailure
          sql pool "ALTER TABLE shikigami.audit_held_attempts RENAME TO decision_attempts"
          restored <- expectReport =<< readDecisionReport store prepared.runId
          toJSON restored @?= toJSON positive,
      testCase "fresh connections preserve actual calls, exact JSON and immutable invocation identities" $
        withShikigamiFreshDatabase fixture \connection -> do
          withPool connection \pool -> do
            let hooks = decisionCallHooks (postgresDecisionEvidenceStore pool) Nothing
            first <- expectRight =<< hooks.beginCall context
            hooks.finishCall first CallSucceeded (Just (terminal "provider-1")) >>= (@?= Right ())
            second <- expectRight =<< hooks.beginCall context
            assertBool "lost append gets a fresh actual-attempt identity" (attemptId first /= attemptId second)
            hooks.finishCall second CallSucceeded (Just (terminal "provider-2")) >>= (@?= Right ())
          withPool connection \pool -> do
            report <- expectReport =<< readDecisionReport (postgresDecisionEvidenceStore pool) prepared.runId
            length report.calls @?= 2
            report.complete @?= True
            report.assessment @?= Nothing
            map (\call -> parseDecisionCallId (decisionCallIdText call.callId)) report.calls @?= map (Right . (\call -> call.callId)) report.calls
            map (\call -> decisionCallOrdinalNumber call.ordinal) report.calls @?= [1, 2]
            map (\call -> call.evidence) report.calls @?= [Just (toJSON (terminal "provider-1")), Just (toJSON (terminal "provider-2"))]
            assertBool "input payload is not in operational binding" (all (not . containsPrompt) report.invocations)
            let changed = (prepared & #program .~ ((program & #parameterDigest .~ (programParameterDigest (String "changed"))))) :: PreparedDecision
            ensureInvocation (postgresDecisionEvidenceStore pool) Nothing changed >>= (assertBool "changed state refused" . isLeft),
      testCase "a later decision keeps its own program label and different model" $
        withShikigamiFreshDatabase fixture \connection -> withPool connection \pool -> do
          let store = postgresDecisionEvidenceStore pool
              hooks = decisionCallHooks store Nothing
              secondModel = (model & #modelId .~ (Coordinate.providerCoordinate "model-b") & #alias .~ (fixtureModelAlias "investigate")) :: ModelDescriptor
              secondPrepared = (prepared & #identity .~ (decisionPreparationId (String "invocation-b")) & #label .~ investigationDecisionSlot & #model .~ (secondModel)) :: PreparedDecision
              secondEvidence = (terminal "provider-b") {B.requestedModel = "model-b"}
          first <- expectRight =<< hooks.beginCall context
          hooks.finishCall first CallSucceeded (Just (terminal "provider-a")) >>= (@?= Right ())
          second <- expectRight =<< hooks.beginCall (DecisionCallContext secondPrepared secondModel)
          hooks.finishCall second CallSucceeded (Just secondEvidence) >>= (@?= Right ())
          report <- expectReport =<< readDecisionReport store prepared.runId
          map (\call -> Coordinate.providerCoordinateText call.model.modelId) report.calls @?= ["model-a", "model-b"]
          length report.invocations @?= 2,
      testCase "unresolved expectation survives loss of all process-local hooks" $
        withShikigamiFreshDatabase fixture \connection -> do
          withPool connection \pool -> do
            let hooks = decisionCallHooks (postgresDecisionEvidenceStore pool) Nothing
            _ <- expectRight =<< hooks.beginCall context
            pure ()
          withPool connection \pool -> do
            report <- expectReport =<< finalizeDecisionReport (postgresDecisionEvidenceStore pool) prepared.runId
            length report.calls @?= 1
            report.complete @?= False
            map (\call -> call.terminal) report.calls @?= [Nothing],
      testCase "failed and unknown terminals without provider evidence remain valid uncertain spending" $
        withShikigamiFreshDatabase fixture \connection -> withPool connection \pool -> do
          let store = postgresDecisionEvidenceStore pool
              hooks = decisionCallHooks store Nothing
          first <- expectRight =<< hooks.beginCall context
          hooks.finishCall first CallUnknown Nothing >>= (@?= Right ())
          second <- expectRight =<< hooks.beginCall context
          hooks.finishCall second CallFailed Nothing >>= (@?= Right ())
          report <- expectReport =<< readDecisionReport store prepared.runId
          report.complete @?= False
          map (\call -> (call.terminal, call.facts, call.evidence)) report.calls @?= [(Just CallUnknown, Nothing, Nothing), (Just CallFailed, Nothing, Nothing)]
          page <- expectRight =<< listDecisionCalls store prepared.runId 0 20
          page @?= report.calls
          hooks.finishCall first CallUnknown Nothing >>= (@?= Right ()),
      testCase "identical terminal writes converge and conflicting evidence is refused" $
        withShikigamiFreshDatabase fixture \connection -> withPool connection \pool -> do
          let store = postgresDecisionEvidenceStore pool
              hooks = decisionCallHooks store Nothing
          token <- expectRight =<< hooks.beginCall context
          let wrongOrdinal = mustRight (parseDecisionCallOrdinal 2)
          hooks.finishCall (withAttemptOrdinal wrongOrdinal token) CallSucceeded (Just (terminal "provider-1")) >>= (assertBool "wrong ordinal refused" . isLeft)
          before <- expectReport =<< readDecisionReport store prepared.runId
          map (\call -> call.terminal) before.calls @?= [Nothing]
          hooks.finishCall token CallSucceeded (Just (terminal "provider-1")) >>= (@?= Right ())
          hooks.finishCall token CallSucceeded (Just (terminal "provider-1")) >>= (@?= Right ())
          hooks.finishCall token CallSucceeded (Just (terminal "provider-2")) >>= (assertBool "conflict refused" . isLeft)
          report <- expectReport =<< readDecisionReport store prepared.runId
          length report.calls @?= 1
          listDecisionCalls store prepared.runId 0 1 >>= (\result -> length (mustRight result) @?= 1)
          listDecisionCalls store prepared.runId 1 1000 >>= (@?= Right []),
      testCase "terminal write faults roll back facts and successful markers together" $
        withShikigamiFreshDatabase fixture \connection -> withPool connection \pool -> do
          let store = postgresDecisionEvidenceStore pool
              hooks = decisionCallHooks store Nothing
          token <- expectRight =<< hooks.beginCall context
          sql pool "CREATE FUNCTION shikigami.reject_decision_terminal() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RAISE EXCEPTION ''fixture terminal fault''; END'; CREATE TRIGGER reject_decision_terminal BEFORE UPDATE ON shikigami.decision_attempts FOR EACH ROW EXECUTE FUNCTION shikigami.reject_decision_terminal();"
          hooks.finishCall token CallSucceeded (Just (terminal "provider-1")) >>= (assertBool "write failure returned" . isLeft)
          report <- expectReport =<< readDecisionReport store prepared.runId
          report.complete @?= False
          map (\call -> (call.terminal, call.facts, call.evidence)) report.calls @?= [(Nothing, Nothing, Nothing)],
      testCase "unsupported persisted fact versions fail closed" $
        withShikigamiFreshDatabase fixture \connection -> withPool connection \pool -> do
          let store = postgresDecisionEvidenceStore pool
              hooks = decisionCallHooks store Nothing
          token <- expectRight =<< hooks.beginCall context
          hooks.finishCall token CallSucceeded (Just (terminal "provider-1")) >>= (@?= Right ())
          positive <- expectReport =<< readDecisionReport store prepared.runId
          positive.complete @?= True
          sql pool "UPDATE shikigami.decision_attempts SET facts=jsonb_set(facts,'{format}','999'::jsonb),terminal=jsonb_set(terminal,'{facts,format}','999'::jsonb)"
          result <- readDecisionReport store prepared.runId
          either (Right . failureCode) (const (Left ())) result @?= Right UnsupportedVersion,
      testCase "malformed retained call identity is a data refusal before further admission" $
        withShikigamiFreshDatabase fixture \connection -> withPool connection \pool -> do
          let store = postgresDecisionEvidenceStore pool
              hooks = decisionCallHooks store Nothing
          _ <- expectRight =<< hooks.beginCall context
          positive <- expectReport =<< readDecisionReport store prepared.runId
          length positive.calls @?= 1
          sql pool "UPDATE shikigami.decision_attempts SET call_id='a9de02c6-e1e1-4a0f-9e9a-0fa48b8114af'"
          readDecisionReport store prepared.runId >>= (\result -> either (Right . failureCode) (const (Left ())) result @?= Right UnsupportedVersion)
          listDecisionCalls store prepared.runId 0 10 >>= (\result -> either (Right . failureCode) (const (Left ())) result @?= Right UnsupportedVersion)
          hooks.beginCall context >>= (\result -> either (Right . failureCode) (const (Left ())) result @?= Right UnsupportedVersion),
      testCase "run-wide call ceilings survive store reconstruction" $
        withShikigamiFreshDatabase fixture \connection -> do
          let policy = profile ((P.unlimitedProfileLimits & #maxCalls .~ (Just (either (error . show) id (PV.mkCeiling 1)))))
              pinned = (prepared & #policy .~ (Just (resolvedProfileView policy).ref)) :: PreparedDecision
              pinnedContext = DecisionCallContext pinned model
          withPool connection \pool -> do
            _ <- expectRight =<< (decisionCallHooks (postgresDecisionEvidenceStore pool) (Just policy)).beginCall pinnedContext
            pure ()
          withPool connection \pool -> do
            let hooks = decisionCallHooks (postgresDecisionEvidenceStore pool) (Just policy)
            hooks.beginCall pinnedContext >>= (assertBool "old expectation still consumes call capacity" . isLeft),
      testCase "concurrent admissions serialize against the same run ceiling" $
        withShikigamiFreshDatabase fixture \connection -> withPool connection \pool -> do
          let policy = profile ((P.unlimitedProfileLimits & #maxCalls .~ (Just (either (error . show) id (PV.mkCeiling 1)))))
              pinned = (prepared & #policy .~ (Just (resolvedProfileView policy).ref)) :: PreparedDecision
              hooks = decisionCallHooks (postgresDecisionEvidenceStore pool) (Just policy)
          a <- newEmptyMVar
          b <- newEmptyMVar
          _ <- forkIO (hooks.beginCall (DecisionCallContext pinned model) >>= putMVar a)
          _ <- forkIO (hooks.beginCall (DecisionCallContext pinned model) >>= putMVar b)
          results <- sequence [takeMVar a, takeMVar b]
          length [() | Right _ <- results] @?= 1
          report <- expectReport =<< readDecisionReport (postgresDecisionEvidenceStore pool) prepared.runId
          map (\call -> decisionCallOrdinalNumber call.ordinal) report.calls @?= [1],
      testCase "unknown cost cannot become zero after a restart and live/resumed assessments agree" $
        withShikigamiFreshDatabase fixture \connection -> do
          let policy = profile ((P.unlimitedProfileLimits & #maxCostMicroUsd .~ (Just (either (error . show) id (PV.mkCeiling 1000)))))
              pinned = (prepared & #policy .~ (Just (resolvedProfileView policy).ref)) :: PreparedDecision
              pinnedContext = DecisionCallContext pinned model
          withPool connection \pool -> do
            let hooks = decisionCallHooks (postgresDecisionEvidenceStore pool) (Just policy)
            token <- expectRight =<< hooks.beginCall pinnedContext
            hooks.finishCall token CallSucceeded (Just (terminal "provider-1")) >>= (@?= Right ())
          withPool connection \pool -> do
            let store = postgresDecisionEvidenceStore pool
                hooks = decisionCallHooks store (Just policy)
            report <- expectReport =<< readDecisionReport store prepared.runId
            let facts = [fact | call <- report.calls, Just fact <- [call.facts]]
                expected = [ExpectedCall (callCorrelationId prepared.runId (decisionCallIdText call.callId) 0) RootCall (providerAttempt (decisionCallOrdinalNumber call.ordinal)) | call <- report.calls]
            report.assessment @?= Just (evaluateCallFacts (resolvedProfileView policy).profile expected facts)
            assertBool "uncertain cost blocks a clean assessment" (maybe False (\assessment -> assessment.sanctioned == ComplianceNonConforming) report.assessment)
            hooks.beginCall pinnedContext >>= (assertBool "uncertainty is not reset" . isLeft)
    ]

-- Each case starts from two complete public attempts and a cached public report.
-- The valid first member proves that a corrupt second member is not omitted.
metadataCases :: [(String, Maybe ResolvedProfile, Text)]
metadataCases =
  [(name, Nothing, "UPDATE shikigami.decision_attempts SET " <> mutation <> " WHERE ordinal=2") | (name, mutation) <- callCases]
    <> [(name, Nothing, "UPDATE shikigami.decision_invocations SET binding=" <> mutation <> " WHERE binding->>'label'='investigate'") | (name, mutation) <- bindingCases]
    <> [(name, Just (profile P.unlimitedProfileLimits), "UPDATE shikigami.decision_runs SET profile=" <> mutation) | (name, mutation) <- profileCases]
  where
    callCases =
      [ ("terminal JSON null cannot become unresolved absence", "terminal='null'::jsonb"),
        ("missing terminal disposition refuses", "terminal=terminal-'terminal'"),
        ("missing complete-envelope facts member refuses", "terminal=terminal-'facts'"),
        ("orphan facts cannot become an unresolved expectation", "terminal=NULL,finished_at=NULL"),
        ("matching columns still reject unsupported facts", "facts=jsonb_set(facts,'{format}','999'),terminal=jsonb_set(terminal,'{facts,format}','999')"),
        ("unknown provider correlation field refuses", "facts=jsonb_set(facts,'{correlationFields}','[\"unknown\"]'),terminal=jsonb_set(terminal,'{facts,correlationFields}','[\"unknown\"]')"),
        ("empty requested model alias refuses", "facts=jsonb_set(facts,'{requestedAlias}','\"\"'),terminal=jsonb_set(terminal,'{facts,requestedAlias}','\"\"')"),
        ("invented known retry lineage refuses", "facts=jsonb_set(facts,'{relationshipKnown}','true'),terminal=jsonb_set(terminal,'{facts,relationshipKnown}','true')"),
        ("unrelated local facts correlation refuses", "facts=jsonb_set(facts,'{callId}','\"unrelated\"'),terminal=jsonb_set(terminal,'{facts,callId}','\"unrelated\"')"),
        ("denormalized evidence disagreement refuses", "evidence='\"substituted\"'::jsonb"),
        ("complete-envelope evidence absence refuses", "terminal=jsonb_set(terminal,'{evidence}','null')"),
        ("invalid model registration refuses", "effective_model=jsonb_set(effective_model,'{version}','\"\"')"),
        ("typed model substitution cannot change invocation ownership", "effective_model=jsonb_set(effective_model,'{modelId}','\"different-model\"')"),
        ("unrelated call correlation refuses", "correlation_id='unrelated'")
      ]
    bindingCases =
      [ ("invocation JSON null refuses the whole report", "'null'::jsonb"),
        ("missing input commitment refuses", "binding-'inputDigest'"),
        ("unproducible input commitment refuses", "jsonb_set(binding,'{inputDigest}','\"sha256:short\"')"),
        ("unsupported invocation format refuses", "jsonb_set(binding,'{format}','2')"),
        ("negative invocation generation refuses", "jsonb_set(binding,'{generation}','-1')"),
        ("invocation identity must agree with its relational key", "jsonb_set(binding,'{identity}','\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"')"),
        ("invocation run must agree with its relational key", "jsonb_set(binding,'{runId}','\"different-run\"')"),
        ("invocation policy must agree with the retained run", "jsonb_set(binding,'{policy}','{\"profileId\":\"different\",\"version\":\"1\",\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}')")
      ]
    profileCases =
      [ ("missing pinned profile cannot become an unconstrained run", "'null'::jsonb"),
        ("profile content cannot change behind its commitment", "jsonb_set(profile,'{profile,version}','\"changed\"')"),
        ("profile reference must name the same content", "jsonb_set(profile,'{ref,profileId}','\"different\"')"),
        ("malformed pinned profile commitment refuses", "jsonb_set(profile,'{ref,digest}','\"sha256:short\"')"),
        ("negative pinned policy ceiling refuses", "jsonb_set(profile,'{profile,limits,maxCalls}','-1')"),
        ("negative retained duration refuses", "jsonb_set(profile,'{profile,limits,maxDurationSeconds}','-1')"),
        ("negative retained retention refuses", "jsonb_set(profile,'{profile,signerRequirements,retentionDays}','-1')")
      ]

metadataRefusal :: DatabaseFixture -> Maybe ResolvedProfile -> Text -> IO ()
metadataRefusal fixture pinned mutation = withShikigamiFreshDatabase fixture \connection -> withPool connection \pool -> do
  let original = prepared & #policy .~ ((\value -> (resolvedProfileView value).ref) <$> pinned)
      later = original & #identity .~ decisionPreparationId (String "second-invocation") & #label .~ investigationDecisionSlot
      replacement = original & #identity .~ decisionPreparationId (String "replacement-invocation")
      store = postgresDecisionEvidenceStore pool
      hooks = decisionCallHooks store pinned
  first <- expectRight =<< hooks.beginCall (DecisionCallContext original model)
  hooks.finishCall first CallSucceeded (Just (terminal "provider-1")) >>= (@?= Right ())
  second <- expectRight =<< hooks.beginCall (DecisionCallContext later model)
  hooks.finishCall second CallSucceeded (Just (terminal "provider-2")) >>= (@?= Right ())
  positive <- expectReport =<< finalizeDecisionReport store original.runId
  positive.complete @?= True
  length positive.calls @?= 2
  length positive.invocations @?= 2
  map (\call -> call.evidence) positive.calls @?= [Just (toJSON (terminal "provider-1")), Just (toJSON (terminal "provider-2"))]
  sql pool "CREATE TABLE shikigami.audit_decision_calls AS SELECT * FROM shikigami.decision_attempts; CREATE TABLE shikigami.audit_decision_invocations AS SELECT * FROM shikigami.decision_invocations; CREATE TABLE shikigami.audit_decision_runs AS SELECT * FROM shikigami.decision_runs"
  originalCalls <- readJSON pool callsSnapshot
  originalInvocations <- readJSON pool invocationsSnapshot
  originalRun <- readJSON pool runSnapshot
  sql pool mutation
  corruptCalls <- readJSON pool callsSnapshot
  corruptInvocations <- readJSON pool invocationsSnapshot
  corruptRun <- readJSON pool runSnapshot
  ownerRefusal =<< readDecisionReport store original.runId
  ownerRefusal =<< listDecisionCalls store original.runId 0 20
  ownerRefusal =<< finalizeDecisionReport store original.runId
  ownerRefusal =<< hooks.finishCall second CallSucceeded (Just (terminal "provider-2"))
  -- Admission may tentatively insert a distinct invocation before reading old
  -- spending. Corruption must condemn that insert as well as refuse dispatch.
  ownerRefusal =<< hooks.beginCall (DecisionCallContext replacement model)
  forM_ [readDecisionReportTx original.runId >> pure (), listDecisionCallsTx original.runId 0 20 >> pure ()] \ignoredRead -> do
    transactionResult <-
      expectRight
        =<< Pool.use
          pool
          ( Sessions.transaction Sessions.ReadCommitted Sessions.Write do
              Tx.sql "UPDATE shikigami.decision_runs SET report='\"tentative-before\"'::jsonb"
              ignoredRead
              Tx.sql "UPDATE shikigami.decision_runs SET report='\"tentative-after\"'::jsonb"
          )
    transactionResult @?= ()
    readJSON pool runSnapshot >>= (@?= corruptRun)
  readJSON pool callsSnapshot >>= (@?= corruptCalls)
  readJSON pool invocationsSnapshot >>= (@?= corruptInvocations)
  readJSON pool runSnapshot >>= (@?= corruptRun)
  sql pool "UPDATE shikigami.decision_attempts a SET correlation_id=b.correlation_id,invocation_id=b.invocation_id,ordinal=b.ordinal,effective_model=b.effective_model,terminal=b.terminal,facts=b.facts,evidence=b.evidence,finished_at=b.finished_at FROM shikigami.audit_decision_calls b WHERE a.call_id=b.call_id; UPDATE shikigami.decision_invocations i SET binding=b.binding FROM shikigami.audit_decision_invocations b WHERE i.invocation_id=b.invocation_id; UPDATE shikigami.decision_runs r SET profile=b.profile,report=b.report FROM shikigami.audit_decision_runs b WHERE r.run_id=b.run_id"
  restored <- expectReport =<< readDecisionReport store original.runId
  toJSON restored @?= toJSON positive
  hooks.finishCall second CallSucceeded (Just (terminal "provider-2")) >>= (@?= Right ())
  readJSON pool callsSnapshot >>= (@?= originalCalls)
  readJSON pool invocationsSnapshot >>= (@?= originalInvocations)
  readJSON pool runSnapshot >>= (@?= originalRun)
  where
    callsSnapshot = "SELECT jsonb_agg(to_jsonb(a) ORDER BY ordinal) FROM shikigami.decision_attempts a"
    invocationsSnapshot = "SELECT jsonb_agg(to_jsonb(i) ORDER BY invocation_id) FROM shikigami.decision_invocations i"
    runSnapshot = "SELECT to_jsonb(r) FROM shikigami.decision_runs r"

ownerRefusal :: Either DecisionFailure a -> IO ()
ownerRefusal result = either (Right . failureCode) (const (Left ())) result @?= Right UnsupportedVersion

readJSON :: Pool -> Text -> IO Value
readJSON pool query = expectRight =<< Pool.use pool (Session.statement () (preparable query E.noParams (D.singleRow (D.column (D.nonNullable D.jsonb)))))

withPool :: Text -> (Pool -> IO a) -> IO a
withPool connection use = withStore (defaultConnectionSettings connection) (use . (.pool))

sql :: Pool -> Text -> IO ()
sql pool query = Pool.use pool (Session.script query) >>= either (assertFailure . show) pure

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (assertFailure . show) pure

expectReport :: Either DecisionFailure (Maybe DecisionEvidenceReport) -> IO DecisionEvidenceReport
expectReport result = expectRight result >>= maybe (assertFailure "expected decision report") pure

mustRight :: (Show e) => Either e a -> a
mustRight = either (error . show) id

containsPrompt :: Value -> Bool
containsPrompt = ("PROMPT_MARKER" `Text.isInfixOf`) . Text.pack . show

fixtureModelAlias :: AliasText.Text -> Alias.ModelAlias
fixtureModelAlias = either (error . show) id . Alias.parseModelAlias

fixtureModelRegistration :: AliasText.Text -> Model.ModelRegistration scope
fixtureModelRegistration = either (error . show) id . Model.parseModelRegistration
