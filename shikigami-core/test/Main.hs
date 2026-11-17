module Main (main) where

import Data.Aeson (eitherDecode, object)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Activity.Coordinate
import Shikigami.AdaptiveProposalSpec qualified as AdaptiveProposalSpec
import Shikigami.Agent.Decl (StreamMatch (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.AgentLoaderSpec qualified as AgentLoaderSpec
import Shikigami.AgentRunValueSpec qualified as AgentRunValueSpec
import Shikigami.AgentValueSpec qualified as AgentValueSpec
import Shikigami.AppConfigSpec qualified as AppConfigSpec
import Shikigami.AttestationContractsSpec qualified as AttestationContractsSpec
import Shikigami.AuthoritySpec qualified as AuthoritySpec
import Shikigami.BaikaiStructuredContentSpec qualified as BaikaiStructuredContentSpec
import Shikigami.BehaviorInputSpec qualified as BehaviorInputSpec
import Shikigami.BehaviorProviderSpec qualified as BehaviorProviderSpec
import Shikigami.BehaviorRetrySpec qualified as BehaviorRetrySpec
import Shikigami.BehaviorToolSpec qualified as BehaviorToolSpec
import Shikigami.CapabilityOverlaySpec qualified as CapabilityOverlaySpec
import Shikigami.CapabilityProviderSpec qualified as CapabilityProviderSpec
import Shikigami.CodingAgentSpec qualified as CodingAgentSpec
import Shikigami.DecisionContractSpec qualified as DecisionContractSpec
import Shikigami.DecisionModelCatalogSpec qualified as DecisionModelCatalogSpec
import Shikigami.DecisionRunnerSpec qualified as DecisionRunnerSpec
import Shikigami.DeclaredToolsSpec qualified as DeclaredToolsSpec
import Shikigami.DelegateContextSpec qualified as DelegateContextSpec
import Shikigami.DelegationBatchSpec qualified as DelegationBatchSpec
import Shikigami.DirectorySpec qualified as DirectorySpec
import Shikigami.DirectoryValueSpec qualified as DirectoryValueSpec
import Shikigami.EnqueueHardeningSpec qualified as EnqueueHardeningSpec
import Shikigami.ExecutionPolicySpec qualified as ExecutionPolicySpec
import Shikigami.ExecutionPositionSpec qualified as ExecutionPositionSpec
import Shikigami.ExecutionResourcesSpec qualified as ExecutionResourcesSpec
import Shikigami.ExecutionSelectionSpec qualified as ExecutionSelectionSpec
import Shikigami.FlowPackSpec qualified as FlowPackSpec
import Shikigami.FormatVersionSpec qualified as FormatVersionSpec
import Shikigami.Integration.Danwa (AddressedMessage (..), addressedMessageEventType)
import Shikigami.KeiroSpecificationSpec qualified as KeiroSpecificationSpec
import Shikigami.KernelBoundarySpec qualified as KernelBoundarySpec
import Shikigami.LocalHostSpec qualified as LocalHostSpec
import Shikigami.LocalOperatorSpec qualified as LocalOperatorSpec
import Shikigami.LogSpec qualified as LogSpec
import Shikigami.MandateSpec qualified as MandateSpec
import Shikigami.ObjectiveSpec qualified as ObjectiveSpec
import Shikigami.ObjectiveToolsSpec qualified as ObjectiveToolsSpec
import Shikigami.ObjectiveTrackerSpec qualified as ObjectiveTrackerSpec
import Shikigami.OutputsSpec qualified as OutputsSpec
import Shikigami.PackageArchitectureSpec qualified as PackageArchitectureSpec
import Shikigami.PayloadValueSpec qualified as PayloadValueSpec
import Shikigami.PlaybookSpec qualified as PlaybookSpec
import Shikigami.ProcessLocalSpec qualified as ProcessLocalSpec
import Shikigami.RecordInvariantSpec qualified as RecordInvariantSpec
import Shikigami.RecordSpec qualified as RecordSpec
import Shikigami.RouterCatalogSpec qualified as RouterCatalogSpec
import Shikigami.RouterDecisionSpec qualified as RouterDecisionSpec
import Shikigami.RouterDeclarationSpec qualified as RouterDeclarationSpec
import Shikigami.SinkAuthSpec qualified as SinkAuthSpec
import Shikigami.SinkIntentSpec qualified as SinkIntentSpec
import Shikigami.Trigger.Schedule (isDue, nextDue, parseCron)
import Shikigami.Trigger.Stream (IncludeAgentActors (IncludeAgentActors), matchesStream, matchesStreamWith)
import Shikigami.TypeSafeDecisionSpec qualified as TypeSafeDecisionSpec
import Shikigami.WireCompatSpec qualified as WireCompatSpec
import Shikigami.WorkerSessionPositionSpec qualified as WorkerSessionPositionSpec
import Shikigami.WorkspaceAdapterSpec qualified as WorkspaceAdapterSpec
import Shikigami.WorkspaceCatalogSpec qualified as WorkspaceCatalogSpec
import Shikigami.WorkspaceInstructionsSpec qualified as WorkspaceInstructionsSpec
import Shikigami.WorkspaceProcessPolicySpec qualified as WorkspaceProcessPolicySpec
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

main :: IO ()
main =
  defaultMain
    ( testGroup
        "shikigami"
        [ testGroup "Trigger" [scheduleTests, streamTests, danwaIntegrationTests],
          AgentValueSpec.tests,
          AgentRunValueSpec.tests,
          PayloadValueSpec.tests,
          WorkspaceCatalogSpec.tests,
          WorkspaceInstructionsSpec.tests,
          WorkspaceProcessPolicySpec.tests,
          WorkspaceAdapterSpec.tests,
          AgentLoaderSpec.tests,
          ObjectiveSpec.tests,
          MandateSpec.tests,
          AdaptiveProposalSpec.tests,
          ObjectiveTrackerSpec.tests,
          ObjectiveToolsSpec.tests,
          AppConfigSpec.tests,
          AttestationContractsSpec.tests,
          BehaviorInputSpec.tests,
          BehaviorProviderSpec.tests,
          BehaviorRetrySpec.tests,
          BehaviorToolSpec.tests,
          CapabilityOverlaySpec.tests,
          CapabilityProviderSpec.tests,
          DecisionContractSpec.tests,
          DecisionModelCatalogSpec.tests,
          DecisionRunnerSpec.tests,
          TypeSafeDecisionSpec.tests,
          BaikaiStructuredContentSpec.tests,
          DelegateContextSpec.tests,
          DelegationBatchSpec.tests,
          ExecutionPositionSpec.tests,
          FormatVersionSpec.tests,
          ExecutionPolicySpec.tests,
          ExecutionResourcesSpec.tests,
          WorkerSessionPositionSpec.tests,
          ExecutionSelectionSpec.tests,
          DirectorySpec.tests,
          DirectoryValueSpec.tests,
          EnqueueHardeningSpec.tests,
          KeiroSpecificationSpec.tests,
          LogSpec.tests,
          PackageArchitectureSpec.tests,
          FlowPackSpec.tests,
          KernelBoundarySpec.tests,
          AuthoritySpec.tests,
          RecordSpec.tests,
          RecordInvariantSpec.tests,
          LocalOperatorSpec.tests,
          LocalHostSpec.tests,
          DeclaredToolsSpec.tests,
          OutputsSpec.tests,
          PlaybookSpec.tests,
          ProcessLocalSpec.tests,
          CodingAgentSpec.tests,
          RouterCatalogSpec.tests,
          RouterDecisionSpec.tests,
          RouterDeclarationSpec.tests,
          SinkIntentSpec.tests,
          SinkAuthSpec.tests,
          WireCompatSpec.tests
        ]
    )

-- ── Trigger.Schedule ────────────────────────────────────────────────────────

atHour :: Int -> UTCTime
atHour h = UTCTime (fromGregorian 2026 6 20) (secondsToDiffTime (fromIntegral h * 3600))

scheduleTests :: TestTree
scheduleTests =
  testGroup
    "Schedule"
    [ testCase "every-minute cron is always due" $
        case parseCron "* * * * *" of
          Right c -> assertBool "due at any time" (isDue c (atHour 3))
          Left e -> assertBool ("parse failed: " <> show e) False,
      testCase "0 9 * * * is due at 09:00, not at 10:00" $
        case parseCron "0 9 * * *" of
          Right c -> do
            assertBool "due at 09:00" (isDue c (atHour 9))
            assertBool "not due at 10:00" (not (isDue c (atHour 10)))
          Left e -> assertBool ("parse failed: " <> show e) False,
      testCase "malformed cron fails to parse" $
        case parseCron "not a cron" of
          Left _ -> pure ()
          Right _ -> assertBool "expected parse failure" False,
      testCase "nextDue is strictly after the supplied minute" $
        case parseCron "* * * * *" of
          Right c -> nextDue c (atHour 3) @?= Just (UTCTime (fromGregorian 2026 6 20) (secondsToDiffTime (3 * 3600 + 60)))
          Left e -> assertBool ("parse failed: " <> show e) False
    ]

-- ── Trigger.Stream ──────────────────────────────────────────────────────────

envelopeWith :: Text -> Text -> Text -> Text -> ActivityEnvelope
envelopeWith actorKind verbV sourceV subjType =
  ActivityEnvelope
    { activityId = activityCoordinate ("act_seed"),
      occurredAt = activityCoordinate ("2026-06-20T07:00:00Z"),
      source = activityCoordinate (sourceV),
      actor = Actor {kind = either (error . show) id (parseActorKind (actorKind)), id = activityCoordinate ("someone"), session = fmap activityCoordinate (Nothing)},
      subject = Subject {kind = activityCoordinate (subjType), subjectId = activityCoordinate ("i-1")},
      verb = activityCoordinate (verbV),
      payload = object [],
      contextRefs = [],
      idempotencyKey = activityCoordinate ("act_seed")
    }

matchAll :: StreamMatch
matchAll = StreamMatch {verb = fmap activityCoordinate (Just "intention.declared"), source = fmap activityCoordinate (Nothing), subjectType = fmap activityCoordinate (Just "intention"), verbs = map activityCoordinate ([])}

streamTests :: TestTree
streamTests =
  testGroup
    "Stream"
    [ testCase "matches on verb + subjectType (human actor)" $
        assertBool "should match" (matchesStream matchAll (envelopeWith "human" "intention.declared" "shinzui/rei" "intention")),
      testCase "absent predicate is ignored (source = Nothing)" $
        assertBool "should match regardless of source" (matchesStream matchAll (envelopeWith "human" "intention.declared" "any/source" "intention")),
      testCase "non-match on differing verb" $
        assertBool "should not match" (not (matchesStream matchAll (envelopeWith "human" "ticket.received" "shinzui/rei" "intention"))),
      testCase "feedback guard: actor.kind=agent excluded by default" $
        assertBool "agent actor excluded" (not (matchesStream matchAll (envelopeWith "agent" "intention.declared" "shinzui/rei" "intention"))),
      testCase "opt-in includes agent actors" $
        assertBool "agent actor included with opt-in" (matchesStreamWith IncludeAgentActors matchAll (envelopeWith "agent" "intention.declared" "shinzui/rei" "intention"))
    ]

danwaIntegrationTests :: TestTree
danwaIntegrationTests =
  testGroup
    "DanwaIntegration"
    [ testCase "decodes the public addressed-message payload" do
        let payload =
              """
              {"conversationId":"conv_public_1","messageId":"msg_public_1","parentMessageId":null,
               "author":"part_human_test","content":"please help","agentParticipantId":"part_agent_test",
               "embellishmentId":"emb_public_1","mentionedBy":"part_human_test",
               "occurredAt":"2026-06-27T00:00:00Z"}
              """
        case eitherDecode @AddressedMessage payload of
          Left err -> assertBool ("decode failed: " <> err) False
          Right msg ->
            msg
              @?= AddressedMessage
                { conversationId = (declarationCoordinate "conv_public_1"),
                  messageId = (declarationCoordinate "msg_public_1"),
                  parentMessageId = Nothing,
                  author = (declarationCoordinate "part_human_test"),
                  content = "please help",
                  agentParticipantId = (declarationCoordinate "part_agent_test"),
                  embellishmentId = (declarationCoordinate "emb_public_1"),
                  mentionedBy = (declarationCoordinate "part_human_test"),
                  occurredAt = UTCTime (fromGregorian 2026 6 27) 0
                },
      testCase "uses Danwa's public integration event type" $
        addressedMessageEventType @?= "danwa.message-addressed-to-agent"
    ]
