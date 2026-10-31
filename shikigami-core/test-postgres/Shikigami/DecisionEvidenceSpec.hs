{-# LANGUAGE DataKinds #-}

module Shikigami.DecisionEvidenceSpec (tests) where

import Baikai.Evidence qualified as B
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Lens ((&), (.~))
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as AliasText
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Attestation.Compliance (ComplianceRollUp (..), evaluateCallFacts)
import Shikigami.Attestation.Envelope (profileDigest)
import Shikigami.Attestation.Evidence (CallRelationship (RootCall), ExpectedCall (..))
import Shikigami.Attestation.Profile qualified as P
import Shikigami.Attestation.Resolve (ResolvedProfile (..))
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
    "invocation-a"
    (runCorrelationId "run-evidence")
    "workflow-evidence"
    0
    "triage"
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
profile limits = ResolvedProfile content (P.SanctionedExecutionProfileRef (P.ProfileId "test") (P.ProfileVersion "1") (profileDigest content))
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
          prohibitions = (P.defaultProhibitions & #defaultedThinkingAllowed .~ (True)),
          limits,
          minimumEvidenceStrength = P.EvidenceRequestedOnly,
          requiredCorrelationFields = [],
          signerRequirements = P.noSignerRequirements
        }

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "durable decision evidence"
    [ testCase "fresh connections preserve actual calls, exact JSON and immutable invocation identities" $
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
              secondPrepared = (prepared & #identity .~ ("invocation-b") & #label .~ ("investigate") & #model .~ (secondModel)) :: PreparedDecision
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
          sql pool "UPDATE shikigami.decision_attempts SET facts=jsonb_set(facts,'{format}','999'::jsonb)"
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
          let policy = profile ((P.unlimitedProfileLimits & #maxCalls .~ (Just 1)))
              pinned = (prepared & #policy .~ (Just policy.ref)) :: PreparedDecision
              pinnedContext = DecisionCallContext pinned model
          withPool connection \pool -> do
            _ <- expectRight =<< (decisionCallHooks (postgresDecisionEvidenceStore pool) (Just policy)).beginCall pinnedContext
            pure ()
          withPool connection \pool -> do
            let hooks = decisionCallHooks (postgresDecisionEvidenceStore pool) (Just policy)
            hooks.beginCall pinnedContext >>= (assertBool "old expectation still consumes call capacity" . isLeft),
      testCase "concurrent admissions serialize against the same run ceiling" $
        withShikigamiFreshDatabase fixture \connection -> withPool connection \pool -> do
          let policy = profile ((P.unlimitedProfileLimits & #maxCalls .~ (Just 1)))
              pinned = (prepared & #policy .~ (Just policy.ref)) :: PreparedDecision
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
          let policy = profile ((P.unlimitedProfileLimits & #maxCostMicroUsd .~ (Just 1000)))
              pinned = (prepared & #policy .~ (Just policy.ref)) :: PreparedDecision
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
                expected = [ExpectedCall (callCorrelationId prepared.runId (decisionCallIdText call.callId) 0) RootCall (decisionCallOrdinalNumber call.ordinal) | call <- report.calls]
            report.assessment @?= Just (evaluateCallFacts policy.profile expected facts)
            assertBool "uncertain cost blocks a clean assessment" (maybe False (not . (\assessment -> assessment.sanctioned)) report.assessment)
            hooks.beginCall pinnedContext >>= (assertBool "uncertainty is not reset" . isLeft)
    ]

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
