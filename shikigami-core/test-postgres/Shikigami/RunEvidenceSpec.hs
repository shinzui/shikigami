module Shikigami.RunEvidenceSpec (tests) where

import Baikai.Context (emptyContext)
import Baikai.Evidence qualified as Baikai
import Baikai.Options (emptyOptions)
import Baikai.Options qualified as Options
import Baikai.Trace qualified as BaikaiTrace
import Data.Aeson (Value, eitherDecode)
import Data.ByteString.Lazy (ByteString)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff)
import Keiro.Workflow.Types (WorkflowId (..))
import Kioku.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Kioku.Id qualified as NominalId
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Numeric.Natural (Natural)
import Shikigami.Attestation.Agent
import Shikigami.Attestation.Compliance
import Shikigami.Attestation.Compliance qualified as Compliance
import Shikigami.Attestation.Evidence
import Shikigami.Attestation.EvidenceStore
import Shikigami.Attestation.Profile
import Shikigami.Attestation.Reviewed
import Shikigami.Behavior.StubProvider (registerStubProvider, stubModel)
import Shikigami.Log.Correlation
  ( CallCorrelationId,
    RunCorrelationId,
    callCorrelationId,
    renderCallCorrelationId,
    runCorrelationId,
  )
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

tests :: DatabaseFixture -> TestTree
tests databaseFixture =
  testGroup
    "run evidence"
    [ testGroup
        "lifecycle"
        [ testCase "every ordinary transition follows the checked aggregate" do
            profiled <- advancesTo ProfileResolved sampleEvidence
            running <- advancesTo Running profiled
            sealed <- advancesTo EvidenceSealed running
            _attested <- advancesTo Attested sealed
            pure (),
          testCase "each failure verdict is reachable only from running" do
            running <- runningEvidence
            mapM_ (assertTarget running) [NonConforming, Incomplete, Failed],
          testCase "requested cannot seal" do
            transitionEvidence sampleEvidence EvidenceSealed
              `assertTransitionError` IllegalTransition Requested EvidenceSealed,
          testCase "attested is reachable only from evidence-sealed" do
            running <- runningEvidence
            transitionEvidence running Attested
              `assertTransitionError` IllegalTransition Running Attested,
          testCase "attested evidence cannot be reopened" do
            running <- runningEvidence
            sealed <- advancesTo EvidenceSealed running
            attested <- advancesTo Attested sealed
            transitionEvidence attested Running
              `assertTransitionError` IllegalTransition Attested Running
        ],
      testGroup
        "collection"
        [ testCase "Options.evidence carries run, attempt, retry, and required strength" do
            let runId = runCorrelationId "run-evidence-options"
                callId = callCorrelationId runId "run-behavior-v2" 1
                configured =
                  configureEvidenceCall
                    runId
                    callId
                    2
                    (Just "baikai-call-1")
                    Baikai.EvidenceModelObserved
                    emptyOptions
            case Options.evidence configured of
              Nothing -> assertFailure "evidence request was not installed"
              Just request -> do
                assertEqual "run id" "run-evidence-options" (request ^. #runId)
                assertEqual "strictness" (Baikai.EvidenceRequired Baikai.EvidenceModelObserved) (request ^. #strictness)
                assertEqual "attempt" 2 (request ^. #attempt)
                assertEqual "retry provenance" (Just "baikai-call-1") (request ^. #supersedes),
          testCase "an unconfigured call remains opted out" do
            assertEqual "no evidence request" Nothing (Options.evidence emptyOptions),
          testCase "the live trace source collects Baikai evidence with Shikigami correlation" do
            registerStubProvider
            let runId = runCorrelationId "run-evidence-live"
                callId = callCorrelationId runId "run-behavior-v2" 0
                options =
                  configureEvidenceCall
                    runId
                    callId
                    1
                    Nothing
                    Baikai.EvidenceRequestedOnly
                    emptyOptions
            (sink, source) <-
              newEvidenceCollector
                runId
                "run-behavior-v2"
                0
                Baikai.EvidenceRequestedOnly
                Nothing
            _ <- BaikaiTrace.withTrace sink stubModel emptyContext options
            collected <- (.terminalCallsFor) source runId
            case collected of
              [RecordedCallEvidence {callId = collectedId, relationship = RootCall, evidence = terminal}] -> do
                assertEqual "correlation id" (renderCallCorrelationId callId) (renderCallCorrelationId collectedId)
                assertEqual "Baikai run id" "run-evidence-live" (terminal ^. #runId)
                assertEqual "Baikai schema" Baikai.evidenceSchemaVersion (terminal ^. #schemaVersion)
              other -> assertFailure ("expected one root call, got " <> show other),
          testCase "two-call, retry, and child fixtures pin literal Baikai JSON" do
            assertLiteralEvidence "two-call" twoCallEvidenceJson twoCallFirst
            assertLiteralEvidence "retry" retryEvidenceJson retryAttempt
            assertLiteralEvidence "child" childEvidenceJson childRecorded
        ],
      testGroup
        "complete accounting"
        [ testCase "two-call program records two distinct calls exactly once" do
            running <- runningEvidence
            let source = fixtureSource [twoCallFirst, twoCallSecond]
            collected <- collectEvidence source running
            assertCallIds [parentCall0, parentCall1] collected
            replayed <- collectEvidence source collected
            assertCallIds [parentCall0, parentCall1] replayed,
          testCase "retry keeps original and retry linked" do
            running <- runningEvidence
            collected <- collectEvidence (fixtureSource [retryOriginal, retryAttempt]) running
            assertCallIds [parentCall0, parentCall1] collected
            let relationships = [relationship | RecordedCallEvidence {relationship} <- runCalls collected]
            assertEqual "retry relationship" [RootCall, RetryOf parentCall0] relationships,
          testCase "parent will not seal while child runs" do
            running <- runningEvidence
            let parent = recordCall parentRecorded running
            assertEqual
              "pending child"
              (Left (PendingChild "run-evidence-child"))
              (sealEvidence parent BehaviorSucceeded [pendingChild]),
          testCase "parent seals once child is terminal and includes its call once" do
            running <- runningEvidence
            let parent = recordCall parentRecorded running
            sealed <-
              case sealEvidence parent BehaviorSucceeded [terminalChild] of
                Left refusal -> assertFailure ("unexpected seal refusal: " <> show refusal)
                Right value -> pure value
            assertEqual "phase" EvidenceSealed (runPhase sealed)
            assertCallIds [parentCall0, childCall0] sealed,
          testCase "non-terminal behavior prevents sealing" do
            running <- runningEvidence
            assertEqual
              "behavior refusal"
              (Left BehaviorNotTerminal)
              (sealEvidence running BehaviorRunning [])
        ],
      testGroup
        "compliance roll-up"
        [ testCase "a conforming call is sanctioned" do
            evidence <- runningWith [compliantCall]
            assertRollUp True [] baselineProfile evidence,
          testCase "wrong model mutation" do
            evidence <- runningWith [wrongModelCall]
            assertRollUp False [ModelNotPermitted parentCall0Text "model-x"] baselineProfile evidence,
          testCase "thinking translation mutation" do
            evidence <- runningWith [withThinking highThinking compliantCall]
            assertRollUp False [ThinkingTranslationNotPermitted parentCall0Text "high" "adaptive"] baselineProfile evidence,
          testCase "defaulted thinking mutation" do
            evidence <- runningWith [compliantCall]
            assertRollUp False [ProhibitedDefaultThinking parentCall0Text] (profileWithProhibitions (permissiveProhibitions & #defaultedThinkingAllowed .~ False)) evidence,
          testCase "alias mutation" do
            evidence <- runningWith [compliantCall & #requestedAlias .~ Just "friendly-model"]
            assertRollUp False [ProhibitedAlias parentCall0Text "friendly-model" "model-a"] (profileWithProhibitions (permissiveProhibitions & #aliasesAllowed .~ False)) evidence,
          testCase "provider fallback mutation" do
            evidence <- runningWith [compliantCall, providerFallbackCall]
            assertRollUp
              False
              [ProhibitedProviderFallback parentCall1Text "fixture" "other-provider"]
              ( profileWith
                  (allowedCall "fixture" "https" "model-a" :| [allowedCall "other-provider" "https" "model-a"])
                  (permissiveProhibitions & #providerFallbackAllowed .~ False)
                  Baikai.EvidenceRequestedOnly
                  []
                  unlimitedProfileLimits
              )
              evidence,
          testCase "model fallback mutation" do
            evidence <- runningWith [compliantCall, modelFallbackCall]
            assertRollUp
              False
              [ProhibitedModelFallback parentCall1Text "model-a" "model-b"]
              ( profileWith
                  (allowedCall "fixture" "https" "model-a" :| [allowedCall "fixture" "https" "model-b"])
                  (permissiveProhibitions & #modelFallbackAllowed .~ False)
                  Baikai.EvidenceRequestedOnly
                  []
                  unlimitedProfileLimits
              )
              evidence,
          testCase "effort clamping mutation" do
            evidence <- runningWith [withThinking clampedThinking compliantCall]
            assertRollUp
              False
              [ProhibitedEffortClamping parentCall0Text "medium" "low"]
              (profileWithProhibitions (permissiveProhibitions & #effortClampingAllowed .~ False))
              evidence,
          testCase "transport mutation" do
            evidence <- runningWith [withEndpoint cliEndpoint compliantCall]
            assertRollUp
              False
              [ProhibitedTransport parentCall0Text "subprocess"]
              ( profileWith
                  (allowedCall "fixture" "cli" "model-a" :| [])
                  (permissiveProhibitions & #cliTransportsAllowed .~ False)
                  Baikai.EvidenceRequestedOnly
                  []
                  unlimitedProfileLimits
              )
              evidence,
          testCase "endpoint mutation" do
            evidence <- runningWith [compliantCall]
            assertRollUp
              False
              [ProhibitedEndpoint parentCall0Text "https"]
              ( profileWith
                  (allowedCall "fixture" "private" "model-a" :| [])
                  permissiveProhibitions
                  Baikai.EvidenceRequestedOnly
                  []
                  unlimitedProfileLimits
              )
              evidence,
          testCase "missing call mutation" do
            running <- runningEvidence
            let evidence = expectCall (ExpectedCall parentCall0 RootCall 1) running
            assertRollUp False [MissingCallEvidence parentCall0Text] baselineProfile evidence,
          testCase "missing retry mutation" do
            running <- runningEvidence
            let evidence = expectCall (ExpectedCall parentCall1 (RetryOf parentCall0) 2) running
            assertRollUp False [MissingRetryEvidence parentCall1Text 2] baselineProfile evidence,
          testCase "missing continuation mutation" do
            running <- runningEvidence
            let evidence = expectCall (ExpectedCall parentCall1 (ContinuationOf parentCall0) 1) running
            assertRollUp False [MissingContinuationEvidence parentCall1Text] baselineProfile evidence,
          testCase "missing delegated child mutation" do
            running <- runningEvidence
            let evidence = expectDelegatedChild fixtureChildRunId running
            assertRollUp False [MissingDelegatedChildEvidence "run-evidence-child"] baselineProfile evidence,
          testCase "missing correlation mutation" do
            evidence <- runningWith [compliantCall]
            assertRollUp
              False
              [MissingCorrelationField parentCall0Text "providerRequestId"]
              (profileWithRequiredCorrelation ["providerRequestId"])
              evidence,
          testCase "reviewed artifact mutation" do
            evidence <- observeArtifactDigest (DiffDigest "sha256:other") <$> runningWith [compliantCall]
            assertRollUp False [ReviewedArtifactMismatch "sha256:diff" "sha256:other"] baselineProfile evidence,
          testCase "review result mutation" do
            evidence <- observeResultDigests (ResultDigest "sha256:expected") (ResultDigest "sha256:actual") <$> runningWith [compliantCall]
            assertRollUp False [ReviewResultDigestMismatch "sha256:expected" "sha256:actual"] baselineProfile evidence,
          testCase "evidence strength mutation" do
            evidence <- runningWith [compliantCall]
            assertRollUp
              False
              [EvidenceBelowRequiredStrength parentCall0Text Baikai.EvidenceCorrelated Baikai.EvidenceRequestedOnly]
              (profileWithMinimumStrength Baikai.EvidenceCorrelated)
              evidence,
          testCase "limit mutation" do
            evidence <- runningWith [compliantCall]
            assertRollUp
              False
              [LimitExceeded "maxCalls" "0" "1"]
              (profileWithLimits (unlimitedProfileLimits & #maxCalls .~ Just 0))
              evidence,
          testCase "deterministic step is not-applicable, not a fabricated call" do
            running <- runningEvidence
            let evidence = recordDeterministicStep "deterministic-rule" running
            assertRollUp True [NotApplicable "deterministic-rule"] baselineProfile evidence
            assertCallIds [] evidence,
          testCase "two permitted models remain sanctioned" do
            evidence <- runningWith [compliantCall, twoCallSecond]
            assertRollUp
              True
              []
              ( profileWith
                  (allowedCall "fixture" "https" "model-a" :| [allowedCall "fixture" "https" "model-b"])
                  permissiveProhibitions
                  Baikai.EvidenceRequestedOnly
                  []
                  unlimitedProfileLimits
              )
              evidence,
          testCase "evaluation accumulates independent reasons" do
            evidence <- expectDelegatedChild fixtureChildRunId <$> runningWith [wrongModelCall]
            assertRollUp
              False
              [ModelNotPermitted parentCall0Text "model-x", MissingDelegatedChildEvidence "run-evidence-child"]
              baselineProfile
              evidence,
          testCase "finalization chooses sealed or non-conforming lifecycle" do
            sanctionedEvidence <- runningWith [compliantCall]
            rejectedEvidence <- runningWith [wrongModelCall]
            case finalizeCompliance baselineProfile BehaviorSucceeded [] sanctionedEvidence of
              Left refusal -> assertFailure ("sanctioned finalization failed: " <> show refusal)
              Right (finalized, rollUp) -> do
                assertEqual "sealed phase" EvidenceSealed (runPhase finalized)
                assertEqual "sanctioned" True (rollSanctioned rollUp)
            case finalizeCompliance baselineProfile BehaviorSucceeded [] rejectedEvidence of
              Left refusal -> assertFailure ("rejected finalization failed: " <> show refusal)
              Right (finalized, rollUp) -> do
                assertEqual "non-conforming phase" NonConforming (runPhase finalized)
                assertEqual "not sanctioned" False (rollSanctioned rollUp)
        ],
      testGroup
        "durability"
        [ testCase "events and operator rows survive restarts and replay converges" do
            (withShikigamiFreshDatabase databaseFixture) \connectionString -> do
              profiledResult <-
                withEvidenceRuntime connectionString \store ->
                  persistEvidenceTransition store sampleEvidence ProfileResolved Nothing
              profiled <- assertPersisted profiledResult

              runningResult <-
                withEvidenceRuntime connectionString \store ->
                  persistEvidenceTransition store profiled Running Nothing
              running <- assertPersisted runningResult
              missingRollUp <-
                withEvidenceRuntime connectionString \store ->
                  persistEvidenceTransition store running EvidenceSealed Nothing
              assertEqual
                "terminal persistence requires a compliance judgement"
                (Left (MissingComplianceRollUp EvidenceSealed))
                missingRollUp

              let withExpectedCalls =
                    running
                      & expectCall (ExpectedCall parentCall0 RootCall 1)
                      & expectCall (ExpectedCall parentCall1 (RetryOf parentCall0) 2)
                      & expectDelegatedChild fixtureChildRunId
                      & recordCall retryOriginal
                      & recordCall retryAttempt
              closed <-
                case prepareEvidenceClosure withExpectedCalls BehaviorSucceeded [terminalChild] of
                  Left refusal -> assertFailure ("closure failed before persistence: " <> show refusal)
                  Right evidence -> pure evidence
              let rollUp = evaluateCompliance baselineProfile closed
              assertEqual "fixture is sanctioned" True (rollSanctioned rollUp)

              sealedResult <-
                withEvidenceRuntime connectionString \store ->
                  persistEvidenceTransition store closed EvidenceSealed (Just rollUp)
              sealed <- assertPersisted sealedResult
              assertEqual "persisted transition sealed" EvidenceSealed (runPhase sealed)

              stored <- queryStoredEvidence connectionString
              assertStoredClosure stored

              replayedResult <-
                withEvidenceRuntime connectionString \store ->
                  persistEvidenceTransition store closed EvidenceSealed (Just rollUp)
              replayed <- assertPersisted replayedResult
              assertEqual "lost-response replay converges" EvidenceSealed (runPhase replayed)
              assertStoredClosure =<< queryStoredEvidence connectionString

              rejectedProfiledResult <-
                withEvidenceRuntime connectionString \store ->
                  persistEvidenceTransition store rejectedSampleEvidence ProfileResolved Nothing
              rejectedProfiled <- assertPersisted rejectedProfiledResult
              rejectedRunningResult <-
                withEvidenceRuntime connectionString \store ->
                  persistEvidenceTransition store rejectedProfiled Running Nothing
              rejectedRunning <- assertPersisted rejectedRunningResult
              let rejectedEvidence = recordCall rejectedWrongModelCall rejectedRunning
                  rejectedRollUp = evaluateCompliance baselineProfile rejectedEvidence
                  expectedRejection = ModelNotPermitted rejectedCall0Text "model-x"
              assertEqual "rejected fixture accumulates its reason" [expectedRejection] ((.reasons) rejectedRollUp)
              rejectedResult <-
                withEvidenceRuntime connectionString \store ->
                  persistEvidenceTransition store rejectedEvidence NonConforming (Just rejectedRollUp)
              _rejected <- assertPersisted rejectedResult
              StoredRunEvidence {status = rejectedStatus, verdict = rejectedVerdict, reasons = rejectedReasons, calls = rejectedCalls} <-
                queryStoredEvidenceFor connectionString rejectedRunId
              assertEqual "rejected phase survives restart" NonConforming rejectedStatus
              assertEqual "rejected verdict survives restart" (Just VerdictNotSanctioned) rejectedVerdict
              assertEqual "rejection reasons survive restart" [expectedRejection] rejectedReasons
              assertEqual "rejected call survives restart" 1 (length rejectedCalls)
        ]
    ]

withEvidenceRuntime :: Text -> (EvidenceStore -> Eff AppEffects a) -> IO a
withEvidenceRuntime connectionString action =
  withStore (defaultConnectionSettings connectionString) \kirokuStore -> do
    tracer <- noopTracer
    let appEnv =
          AppEnv
            { connectionSettings = defaultConnectionSettings connectionString,
              tracer,
              metrics = Nothing
            }
        store = postgresEvidenceStore (pool kirokuStore)
    result <- runAppIO appEnv (action store)
    either (assertFailure . show) pure result

assertPersisted :: Either EvidencePersistenceError RunEvidence -> IO RunEvidence
assertPersisted = \case
  Left err -> assertFailure ("evidence persistence failed: " <> show err)
  Right evidence -> pure evidence

queryStoredEvidence :: Text -> IO StoredRunEvidence
queryStoredEvidence connectionString =
  queryStoredEvidenceFor connectionString parentRunId

queryStoredEvidenceFor :: Text -> RunCorrelationId -> IO StoredRunEvidence
queryStoredEvidenceFor connectionString requestedRunId =
  withStore (defaultConnectionSettings connectionString) \kirokuStore -> do
    found <- findRunEvidence (postgresEvidenceStore (pool kirokuStore)) requestedRunId
    case found of
      Nothing -> assertFailure "run evidence was absent after restart"
      Just stored -> pure stored

assertStoredClosure :: StoredRunEvidence -> IO ()
assertStoredClosure
  StoredRunEvidence
    { runEvidenceId,
      runId,
      status,
      verdict,
      reasons,
      expectedCallCount,
      recordedCallCount,
      calls
    } = do
    assertEqual "aggregate id" sampleAggregateId runEvidenceId
    assertEqual "run id" "run-evidence-m1" runId
    assertEqual "stored phase" EvidenceSealed status
    assertEqual "stored verdict" (Just VerdictSanctioned) verdict
    assertEqual "stored reasons" [] reasons
    assertEqual "expected calls" 2 expectedCallCount
    assertEqual "recorded calls" 3 recordedCallCount
    assertEqual "query returns every call" 3 (length calls)
    retry <- storedCall parentCall1 calls
    assertEqual "retry relationship" "retry" (storedRelationship retry)
    assertEqual "retry target" (Just parentCall0Text) (storedRelatedCallId retry)
    child <- storedCall childCall0 calls
    assertEqual "child source run" "run-evidence-child" (storedSourceRunId child)
    assertEqual "child relationship" "child" (storedRelationship child)
    assertEqual "child parent call" (Just parentCall0Text) (storedRelatedCallId child)

storedCall :: CallCorrelationId -> [StoredCallEvidence] -> IO StoredCallEvidence
storedCall expected = \case
  [] -> assertFailure ("stored call not found: " <> Text.unpack (renderCallCorrelationId expected))
  call@StoredCallEvidence {callId} : rest
    | callId == renderCallCorrelationId expected -> pure call
    | otherwise -> storedCall expected rest

storedRelationship :: StoredCallEvidence -> Text
storedRelationship StoredCallEvidence {relationship} = relationship

storedRelatedCallId :: StoredCallEvidence -> Maybe Text
storedRelatedCallId StoredCallEvidence {relatedCallId} = relatedCallId

storedSourceRunId :: StoredCallEvidence -> Text
storedSourceRunId StoredCallEvidence {sourceRunId} = sourceRunId

assertTarget :: RunEvidence -> EvidencePhase -> IO ()
assertTarget evidence target = do
  advanced <- advancesTo target evidence
  assertEqual "target phase" target (runPhase advanced)

runningEvidence :: IO RunEvidence
runningEvidence = do
  profiled <- advancesTo ProfileResolved sampleEvidence
  advancesTo Running profiled

advancesTo :: EvidencePhase -> RunEvidence -> IO RunEvidence
advancesTo target evidence =
  case transitionEvidence evidence target of
    Left err -> assertFailure ("unexpected transition error: " <> show err)
    Right advanced -> pure advanced

assertTransitionError :: Either TransitionError RunEvidence -> TransitionError -> IO ()
assertTransitionError actual expected =
  case actual of
    Left err -> assertEqual "transition error" expected err
    Right advanced -> assertFailure ("transition unexpectedly reached " <> show (runPhase advanced))

sampleEvidence :: RunEvidence
sampleEvidence =
  requestEvidence
    sampleAggregateId
    (runCorrelationId "run-evidence-m1")
    sampleAgentVersion
    (declarationOnlyArtifacts (DeclarationDigest "sha256:declaration"))
    sampleReviewed
    sampleProfileRef
    (ReviewRequestId "review-request-1")
    "review-request-1:attempt-1"

sampleAggregateId :: RunEvidenceId
sampleAggregateId =
  either (error . show) id (parseRunEvidenceId "runevidence_01h455vb4pex5vsknk084sn02q")

rejectedSampleEvidence :: RunEvidence
rejectedSampleEvidence =
  sampleEvidence
    & #runEvidenceId
    .~ rejectedAggregateId
    & #runId
    .~ rejectedRunId
    & #idempotencyKey
    .~ "review-request-2:attempt-1"

rejectedAggregateId :: RunEvidenceId
rejectedAggregateId =
  either (error . show) id (parseRunEvidenceId "runevidence_01h455vb4pex5vsknk084sn02r")

rejectedRunId :: RunCorrelationId
rejectedRunId = runCorrelationId "run-evidence-rejected"

rejectedCall0 :: CallCorrelationId
rejectedCall0 = callCorrelationId rejectedRunId "run-behavior-v2" 0

rejectedCall0Text :: Text
rejectedCall0Text = renderCallCorrelationId rejectedCall0

rejectedWrongModelCall :: RecordedCallEvidence
rejectedWrongModelCall =
  fixtureRecorded
    rejectedCall0
    RootCall
    Nothing
    (fixtureEvidence "run-evidence-rejected" "baikai-rejected-model" 1 Nothing "model-x")

sampleAgentVersion :: AgentVersionRef
sampleAgentVersion =
  AgentVersionRef
    { logicalAgentId = LogicalAgentId "reviewer",
      agentVersion = AgentVersion "v1",
      declarationDigest = DeclarationDigest "sha256:declaration"
    }

sampleReviewed :: ReviewedArtifact
sampleReviewed =
  ReviewedArtifact
    { repository = RepositoryId "mori://shinzui/shikigami",
      baseCommit = fullCommit 'a',
      headCommit = fullCommit 'b',
      diffDigest = DiffDigest "sha256:diff",
      pathScope = [],
      pullRequest = Nothing
    }

fullCommit :: Char -> FullCommit
fullCommit character =
  either (error . show) id (mkFullCommit (replicateText 40 character))

replicateText :: Int -> Char -> Text
replicateText count character = Text.pack (replicate count character)

sampleProfileRef :: SanctionedExecutionProfileRef
sampleProfileRef =
  SanctionedExecutionProfileRef
    { profileId = ProfileId "review",
      version = ProfileVersion "v1",
      digest = ProfileDigest "sha256:profile"
    }

fixtureSource :: [RecordedCallEvidence] -> EvidenceSource
fixtureSource terminalCalls =
  EvidenceSource
    { terminalCallsFor = \_ -> pure terminalCalls,
      meetsMinimumStrength = \minimumStrength -> pure (minimumStrength <= Baikai.EvidenceFullyObserved)
    }

parentRunId :: RunCorrelationId
parentRunId = runCorrelationId "run-evidence-m1"

fixtureChildRunId :: RunCorrelationId
fixtureChildRunId = runCorrelationId "run-evidence-child"

parentCall0 :: CallCorrelationId
parentCall0 = callCorrelationId parentRunId "run-behavior-v2" 0

parentCall1 :: CallCorrelationId
parentCall1 = callCorrelationId parentRunId "run-behavior-v2" 1

childCall0 :: CallCorrelationId
childCall0 = callCorrelationId fixtureChildRunId "run-behavior-v2" 0

twoCallFirst :: RecordedCallEvidence
twoCallFirst = fixtureRecorded parentCall0 RootCall Nothing (fixtureEvidence "run-evidence-m1" "baikai-two-1" 1 Nothing "model-a")

twoCallSecond :: RecordedCallEvidence
twoCallSecond = fixtureRecorded parentCall1 RootCall Nothing (fixtureEvidence "run-evidence-m1" "baikai-two-2" 1 Nothing "model-b")

retryOriginal :: RecordedCallEvidence
retryOriginal = fixtureRecorded parentCall0 RootCall Nothing (fixtureEvidence "run-evidence-m1" "baikai-retry-1" 1 Nothing "model-a")

retryAttempt :: RecordedCallEvidence
retryAttempt =
  fixtureRecorded
    parentCall1
    (RetryOf parentCall0)
    Nothing
    (fixtureEvidence "run-evidence-m1" "baikai-retry-2" 2 (Just "baikai-retry-1") "model-a")

parentRecorded :: RecordedCallEvidence
parentRecorded = twoCallFirst

childRecorded :: RecordedCallEvidence
childRecorded =
  fixtureRecorded
    childCall0
    (ChildOf parentCall0)
    Nothing
    (fixtureEvidence "run-evidence-child" "baikai-child-1" 1 Nothing "model-a")

fixtureRecorded :: CallCorrelationId -> CallRelationship -> Maybe Text -> Baikai.ModelCallEvidence -> RecordedCallEvidence
fixtureRecorded callId relationship requestedAlias evidence =
  RecordedCallEvidence
    { callId,
      relationship,
      resolvedModelId = evidence ^. #requestedModel,
      requestedAlias,
      evidence
    }

pendingChild :: RelevantChild
pendingChild =
  RelevantChild
    { childRunId = fixtureChildRunId,
      parentRunWorkflowId = WorkflowId "run-evidence-m1",
      parentSessionId = Just nominalSessionFixture,
      phase = Running,
      calls = []
    }

terminalChild :: RelevantChild
terminalChild =
  RelevantChild
    { childRunId = fixtureChildRunId,
      parentRunWorkflowId = WorkflowId "run-evidence-m1",
      parentSessionId = Just nominalSessionFixture,
      phase = EvidenceSealed,
      calls = [childRecorded]
    }

fixtureEvidence :: Text -> Text -> Natural -> Maybe Text -> Text -> Baikai.ModelCallEvidence
fixtureEvidence runId callId attempt supersedes requestedModel =
  Baikai.baseEvidence
    ( Baikai.evidenceRequest runId
        & #attempt
        .~ attempt
        & #supersedes
        .~ supersedes
    )
    callId
    fixtureEndpoint
    requestedModel
    Baikai.noThinkingRequested
    fixtureTime
    fixtureTime
    Baikai.CallSucceeded
    "sha256:request"
    "sha256:configuration"

fixtureEndpoint :: Baikai.EndpointIdentity
fixtureEndpoint =
  Baikai.EndpointIdentity
    { provider = "fixture",
      api = "messages",
      transport = Baikai.TransportHttpApi,
      endpoint = Just "https://fixture.invalid/v1/messages",
      baikaiVersion = "0.6.0.0",
      implementationVersion = Just "fixture-v1"
    }

fixtureTime :: UTCTime
fixtureTime = UTCTime (fromGregorian 2026 8 19) 0

runCalls :: RunEvidence -> [RecordedCallEvidence]
runCalls RunEvidence {calls} = calls

runPhase :: RunEvidence -> EvidencePhase
runPhase RunEvidence {phase} = phase

assertCallIds :: [CallCorrelationId] -> RunEvidence -> IO ()
assertCallIds expected runEvidence =
  assertEqual
    "accounted call ids"
    (renderCallCorrelationId <$> expected)
    [renderCallCorrelationId callId | RecordedCallEvidence {callId} <- runCalls runEvidence]

runningWith :: [RecordedCallEvidence] -> IO RunEvidence
runningWith terminalCalls = do
  running <- runningEvidence
  pure (foldl' (flip recordCall) running terminalCalls)

assertRollUp :: Bool -> [NonConformingReason] -> SanctionedExecutionProfile -> RunEvidence -> IO ()
assertRollUp expectedSanctioned expectedReasons sanctionedProfile evidence = do
  let ComplianceRollUp {sanctioned, reasons} = evaluateCompliance sanctionedProfile evidence
  assertEqual "sanctioned verdict" expectedSanctioned sanctioned
  assertEqual "all reasons" expectedReasons reasons

rollSanctioned :: ComplianceRollUp -> Bool
rollSanctioned ComplianceRollUp {sanctioned} = sanctioned

parentCall0Text :: Text
parentCall0Text = renderCallCorrelationId parentCall0

parentCall1Text :: Text
parentCall1Text = renderCallCorrelationId parentCall1

compliantCall :: RecordedCallEvidence
compliantCall = twoCallFirst

wrongModelCall :: RecordedCallEvidence
wrongModelCall =
  fixtureRecorded
    parentCall0
    RootCall
    Nothing
    (fixtureEvidence "run-evidence-m1" "baikai-wrong-model" 1 Nothing "model-x")

providerFallbackCall :: RecordedCallEvidence
providerFallbackCall =
  fixtureRecorded
    parentCall1
    (FallbackFrom parentCall0)
    Nothing
    ( fixtureEvidence "run-evidence-m1" "baikai-provider-fallback" 1 Nothing "model-a"
        & #endpoint
        .~ endpointFor "other-provider" Baikai.TransportHttpApi (Just "https://other.invalid/v1/messages")
    )

modelFallbackCall :: RecordedCallEvidence
modelFallbackCall = twoCallSecond & #relationship .~ FallbackFrom parentCall0

withThinking :: Baikai.ThinkingTranslation -> RecordedCallEvidence -> RecordedCallEvidence
withThinking translation recorded =
  recorded & #evidence . #thinking .~ translation

withEndpoint :: Baikai.EndpointIdentity -> RecordedCallEvidence -> RecordedCallEvidence
withEndpoint endpoint recorded =
  recorded & #evidence . #endpoint .~ endpoint

highThinking :: Baikai.ThinkingTranslation
highThinking =
  Baikai.ThinkingTranslation
    { requested = Just ThinkingHigh,
      mode = Baikai.ThinkingModeAdaptive,
      effortText = Nothing,
      budgetTokens = Nothing,
      wireField = Just "thinking",
      adjustments = []
    }

clampedThinking :: Baikai.ThinkingTranslation
clampedThinking =
  Baikai.ThinkingTranslation
    { requested = Just ThinkingMedium,
      mode = Baikai.ThinkingModeAdaptive,
      effortText = Just "low",
      budgetTokens = Nothing,
      wireField = Just "thinking",
      adjustments = [Baikai.EffortClamped ThinkingMedium "low"]
    }

cliEndpoint :: Baikai.EndpointIdentity
cliEndpoint = endpointFor "fixture" Baikai.TransportSubprocess Nothing

endpointFor :: Text -> Baikai.TransportKind -> Maybe Text -> Baikai.EndpointIdentity
endpointFor provider transport endpoint =
  Baikai.EndpointIdentity
    { provider,
      api = "messages",
      transport,
      endpoint,
      baikaiVersion = "0.6.0.0",
      implementationVersion = Just "fixture-v1"
    }

baselineProfile :: SanctionedExecutionProfile
baselineProfile =
  profileWith
    (allowedCall "fixture" "https" "model-a" :| [])
    permissiveProhibitions
    Baikai.EvidenceRequestedOnly
    []
    unlimitedProfileLimits

profileWithProhibitions :: Prohibitions -> SanctionedExecutionProfile
profileWithProhibitions restrictions = baselineProfile & #prohibitions .~ restrictions

profileWithRequiredCorrelation :: [Text] -> SanctionedExecutionProfile
profileWithRequiredCorrelation fields = baselineProfile & #requiredCorrelationFields .~ fields

profileWithMinimumStrength :: Baikai.EvidenceStrength -> SanctionedExecutionProfile
profileWithMinimumStrength strength = baselineProfile & #minimumEvidenceStrength .~ strength

profileWithLimits :: ProfileLimits -> SanctionedExecutionProfile
profileWithLimits limits = baselineProfile & #limits .~ limits

profileWith ::
  NonEmpty AllowedCall ->
  Prohibitions ->
  Baikai.EvidenceStrength ->
  [Text] ->
  ProfileLimits ->
  SanctionedExecutionProfile
profileWith allowedCalls prohibitions minimumEvidenceStrength requiredCorrelationFields limits =
  SanctionedExecutionProfile
    { profileId = ProfileId "review",
      version = ProfileVersion "v1",
      issuer = Issuer "test-issuer",
      lifecycle = Active,
      validFrom = fixtureTime,
      validUntil = Nothing,
      allowedCalls,
      prohibitions,
      limits,
      minimumEvidenceStrength,
      requiredCorrelationFields,
      signerRequirements = noSignerRequirements
    }

allowedCall :: Text -> Text -> Text -> AllowedCall
allowedCall provider endpointClass modelId =
  AllowedCall
    { provider,
      api = "messages",
      endpointClass,
      modelId,
      thinking = ThinkingMedium
    }

permissiveProhibitions :: Prohibitions
permissiveProhibitions =
  Prohibitions
    { aliasesAllowed = True,
      defaultedThinkingAllowed = True,
      providerFallbackAllowed = True,
      modelFallbackAllowed = True,
      effortClampingAllowed = True,
      cliTransportsAllowed = True
    }

assertLiteralEvidence :: String -> ByteString -> RecordedCallEvidence -> IO ()
assertLiteralEvidence label literal RecordedCallEvidence {evidence} =
  case eitherDecode @Value literal of
    Left err -> assertFailure (label <> " fixture literal does not parse: " <> err)
    Right expected -> assertEqual (label <> " evidence JSON") expected (toJSON evidence)

twoCallEvidenceJson :: ByteString
twoCallEvidenceJson =
  """
  {
    "schema_version":"baikai.model-call-evidence/2.0",
    "run_id":"run-evidence-m1",
    "call_id":"baikai-two-1",
    "attempt":1,
    "supersedes":null,
    "endpoint":{"provider":"fixture","api":"messages","transport":"http_api","endpoint":"https://fixture.invalid/v1/messages","baikai_version":"0.6.0.0","implementation_version":"fixture-v1"},
    "requested_model":"model-a",
    "thinking":{"requested":null,"mode":"absent","effort_text":null,"budget_tokens":null,"wire_field":null,"adjustments":[]},
    "observed_model":"unobserved",
    "observed_thinking":"unobserved",
    "response_id":"unobserved",
    "provider_request_id":"unobserved",
    "client_request_id":null,
    "started_at":"2026-08-19T00:00:00Z",
    "ended_at":"2026-08-19T00:00:00Z",
    "latency_ms":0,
    "status":"succeeded",
    "error_info":null,
    "usage":"unobserved",
    "strength":"requested_only",
    "request_commitment":"sha256:request",
    "request_configuration":"sha256:configuration",
    "response_commitment":"unobserved"
  }
  """

retryEvidenceJson :: ByteString
retryEvidenceJson =
  """
  {
    "schema_version":"baikai.model-call-evidence/2.0",
    "run_id":"run-evidence-m1",
    "call_id":"baikai-retry-2",
    "attempt":2,
    "supersedes":"baikai-retry-1",
    "endpoint":{"provider":"fixture","api":"messages","transport":"http_api","endpoint":"https://fixture.invalid/v1/messages","baikai_version":"0.6.0.0","implementation_version":"fixture-v1"},
    "requested_model":"model-a",
    "thinking":{"requested":null,"mode":"absent","effort_text":null,"budget_tokens":null,"wire_field":null,"adjustments":[]},
    "observed_model":"unobserved",
    "observed_thinking":"unobserved",
    "response_id":"unobserved",
    "provider_request_id":"unobserved",
    "client_request_id":null,
    "started_at":"2026-08-19T00:00:00Z",
    "ended_at":"2026-08-19T00:00:00Z",
    "latency_ms":0,
    "status":"succeeded",
    "error_info":null,
    "usage":"unobserved",
    "strength":"requested_only",
    "request_commitment":"sha256:request",
    "request_configuration":"sha256:configuration",
    "response_commitment":"unobserved"
  }
  """

childEvidenceJson :: ByteString
childEvidenceJson =
  """
  {
    "schema_version":"baikai.model-call-evidence/2.0",
    "run_id":"run-evidence-child",
    "call_id":"baikai-child-1",
    "attempt":1,
    "supersedes":null,
    "endpoint":{"provider":"fixture","api":"messages","transport":"http_api","endpoint":"https://fixture.invalid/v1/messages","baikai_version":"0.6.0.0","implementation_version":"fixture-v1"},
    "requested_model":"model-a",
    "thinking":{"requested":null,"mode":"absent","effort_text":null,"budget_tokens":null,"wire_field":null,"adjustments":[]},
    "observed_model":"unobserved",
    "observed_thinking":"unobserved",
    "response_id":"unobserved",
    "provider_request_id":"unobserved",
    "client_request_id":null,
    "started_at":"2026-08-19T00:00:00Z",
    "ended_at":"2026-08-19T00:00:00Z",
    "latency_ms":0,
    "status":"succeeded",
    "error_info":null,
    "usage":"unobserved",
    "strength":"requested_only",
    "request_commitment":"sha256:request",
    "request_configuration":"sha256:configuration",
    "response_commitment":"unobserved"
  }
  """

nominalSessionFixture :: NominalId.SessionId
nominalSessionFixture = either (error . show) id (NominalId.parseId "kioku_session_01kvxa7d2cezhs874g3n8dfgme")
