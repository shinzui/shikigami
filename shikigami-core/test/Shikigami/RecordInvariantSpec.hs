-- | The kernel invariants checked from a run's record (EP-8 M3): a clean
-- run passes, and each 'InvariantViolation' has one synthetic record that
-- produces it.
module Shikigami.RecordInvariantSpec (tests) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Keiro.Workflow (WorkflowId (..))
import Shikigami.Activity.Coordinate (activityCoordinate)
import Shikigami.Agent.RunRecord
import Shikigami.Authority (Action (EmitOutput), mkOutputKind, mkOutputTarget)
import Shikigami.Fixture.OutboxDispatch (unreachableServices)
import Shikigami.Fixture.SinkHttp (testHttpEnv)
import Shikigami.Output (DefaultOutput (..), OutputAdapter (..), OutputDecl (..), OutputReceipt (..), ResolvedOutputs (..), mkOutputRegistry)
import Shikigami.Output.Kikan (defaultKawaDigest, kawaDigestAdapter)
import Shikigami.Record
import Shikigami.Record.Invariant
import Shikigami.Sink.Config (KawaConfig (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "RecordInvariant"
    [ testCase "a clean run holds every invariant and pairs its effect" do
        let result = check [admitted, allowed, delivered, finished]
        result.violations @?= []
        result.linkedEffects @?= 1
        result.unlinkedEffects @?= [],
      testCase "K1: an event without a principal" $
        violationsOf [admitted, by "" allowed, delivered] @?= [MissingPrincipal 1],
      testCase "K1: a second principal" $
        violationsOf [admitted, allowed, by "agent_other" delivered] @?= [PrincipalChanged 2 "agent_portable" "agent_other"],
      testCase "K1: a paused principal acted" $
        violationsOf [admittedWith ["lifecycle" .= ("paused" :: Text)], allowed, delivered] @?= [InactivePrincipalActed "paused" 1, InactivePrincipalActed "paused" 2],
      testCase "K2/K3: an effect with no decision, a refusal, or a later decision" do
        violationsOf [admitted, delivered] @?= [UndecidedEffect 1 "output.delivered" "emit_output" resource]
        violationsOf [admitted, refused, delivered] @?= [UndecidedEffect 2 "output.delivered" "emit_output" resource]
        violationsOf [admitted, delivered, allowed] @?= [UndecidedEffect 1 "output.delivered" "emit_output" resource],
      testCase "K4: no admission, or one with no digest" do
        violationsOf [allowed, delivered] @?= [MissingAdmission]
        violationsOf [admittedWith ["declarationDigest" .= ("" :: Text)], allowed, delivered] @?= [MissingDeclarationDigest],
      testCase "K5: neither a root nor a lease" $
        violationsOf [admittedWith ["timeoutSeconds" .= (0 :: Int), "root" .= Null], allowed, delivered] @?= [UnboundedRun],
      testCase "K6: an effect outside a step, and a repeated effect" do
        violationsOf [admitted, allowed, withPayload delivered ["step" .= ("" :: Text)]] @?= [EffectOutsideStep 2 "output.delivered"]
        violationsOf [admitted, allowed, delivered, delivered] @?= [RepeatedEffect ("output.delivered " <> resource)],
      testCase "K8: two runs admitted under one key" $
        (checkRun RunFacts {run = runId, keyAdmissions = [runId, WorkflowId "run-2", runId]} [admitted]).violations @?= [DuplicateAdmission [runId, WorkflowId "run-2"]],
      testCase "an effect naming no action is counted, not passed" do
        let result = check [admitted, event "process.finished" (object ["rule" .= ("build" :: Text)]), finished]
        result.violations @?= []
        result.unlinkedEffects @?= [("process.finished", 1)],
      testCase "the admission entry says where the outputs came from" do
        let entry = either (error . show) id (admissionEntry (admission (CompositionDefault defaultKawaDigest)))
        snd (recordEntry entry) `hasField` ("outputs", object ["resolution" .= ("composition-default" :: Text), "kinds" .= ["kawa.digest" :: Text]])
        let declared = either (error . show) id (admissionEntry (admission (DeclaredOutputs (defaultKawaDigest :| []))))
        snd (recordEntry declared) `hasField` ("outputs", object ["resolution" .= ("declared" :: Text), "kinds" .= ["kawa.digest" :: Text]])
        let journal = either (error . show) id (admissionEntry (admission JournalOnly))
        snd (recordEntry journal) `hasField` ("outputs", object ["resolution" .= ("journal-only" :: Text), "kinds" .= ([] :: [Text])]),
      testCase "the delivered entry names the exact decided action" do
        let action = EmitOutput (either (error . Text.unpack) id (mkOutputKind "local.report")) (either (error . Text.unpack) id (mkOutputTarget ("run-1" :| ["0"])))
            entry = either (error . show) id (deliveredEntry "deliver-outputs" action OutputReceipt {kind = "local.report", location = "/r/run-1-0.md", detail = "9 bytes"})
            result = check [admitted, allowed, event "output.delivered" (snd (recordEntry entry))]
        result.violations @?= []
        result.linkedEffects @?= 1,
      testCase "kawa.digest needs a subject type and a verb, and is a valid default" do
        let adapter = kawaDigestAdapter unreachableServices
        adapter.validate defaultKawaDigest.config @?= Right ()
        assertBool "verb missing" (isLeft (adapter.validate (object ["subjectType" .= ("agent-run" :: Text)])))
        assertBool "blank subject type" (isLeft (adapter.validate (object ["subjectType" .= ("  " :: Text), "verb" .= ("reported" :: Text)])))
        assertBool "registers as the default" (either (const False) (const True) (mkOutputRegistry [adapter] (DefaultOutput defaultKawaDigest)))
    ]
  where
    hasField value (name, expected) =
      assertBool ("payload carries " <> Text.unpack name) case value of
        Object fields -> KeyMap.lookup (Key.fromText name) fields == Just expected
        _ -> False

runId :: WorkflowId
runId = WorkflowId "run-1"

resource :: Text
resource = "local.report:run-1/0"

check :: [RecordEvent] -> RunCheck
check = checkRun RunFacts {run = runId, keyAdmissions = [runId]}

violationsOf :: [RecordEvent] -> [InvariantViolation]
violationsOf = (.violations) . check

admission :: ResolvedOutputs -> RunAdmission
admission outputs =
  RunAdmission
    { digest = "sha256:abc",
      trigger = "operator",
      idempotencyKey = "key-1",
      root = Nothing,
      timeout = 300,
      lifecycle = "unmanaged",
      outputs
    }

admitted :: RecordEvent
admitted = event "run.admitted" (snd (recordEntry (either (error . show) id (admissionEntry (admission (CompositionDefault defaultReport))))))
  where
    defaultReport = OutputDecl {kind = either (error . Text.unpack) id (mkOutputKind "local.report"), config = object []}

admittedWith :: [(Key.Key, Value)] -> RecordEvent
admittedWith overrides = withPayload admitted overrides

allowed, refused, delivered, finished :: RecordEvent
allowed = event "authority.decided" (object ["action" .= ("emit_output" :: Text), "resource" .= resource, "decision" .= ("allowed" :: Text), "decidedBy" .= ("operator" :: Text)])
refused = event "authority.decided" (object ["action" .= ("emit_output" :: Text), "resource" .= resource, "decision" .= ("denied" :: Text), "decidedBy" .= ("operator" :: Text)])
delivered = event "output.delivered" (object ["action" .= ("emit_output" :: Text), "resource" .= resource, "step" .= ("deliver-outputs" :: Text), "effectKey" .= resource])
finished = event "run.finished" (object ["outcome" .= ("completed" :: Text)])

event :: Text -> Value -> RecordEvent
event kindText payload =
  RecordEvent
    { at = UTCTime (fromGregorian 2026 11 16) 0,
      run = Just runId,
      principal = "agent_portable",
      tier = unspecifiedTier,
      agent = Nothing,
      entry = either (error . show) id (mkRecordEntry (either (error . Text.unpack) id (mkRecordKind kindText)) payload)
    }

by :: Text -> RecordEvent -> RecordEvent
by principal value = value {principal}

withPayload :: RecordEvent -> [(Key.Key, Value)] -> RecordEvent
withPayload value overrides =
  let (kind, payload) = recordEntry value.entry
      merged = case payload of
        Object fields -> Object (foldr (uncurry KeyMap.insert) fields overrides)
        other -> other
   in value {entry = either (error . show) id (mkRecordEntry kind merged)}
