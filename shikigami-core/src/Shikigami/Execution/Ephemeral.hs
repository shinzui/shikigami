-- | Database-free policy execution. Accepted inputs and outcomes live only in
-- this invocation; interruption provides no resumable execution reference.
module Shikigami.Execution.Ephemeral (EphemeralResult (..), runEphemeralBehavior) where

import Baikai.Error (isRetryable)
import Baikai.Provider.Registry (newProviderRegistryFrom)
import Baikai.Response (responseError)
import Baikai.StopReason (StopReason (ToolUse))
import Control.Exception qualified as Exception
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.List (find)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (NominalDiffTime)
import Data.Vector qualified as Vector
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Behavior.Compatibility (renderResponseCompatibilityError, validateResponseRequest)
import Shikigami.Behavior.Error (FailureClass (..), RunError (..), boundedBehaviorDetail, failureClass)
import Shikigami.Behavior.Run (BehaviorEnv (..), BehaviorInput, completeBehaviorRequest, runBehavior)
import Shikigami.Behavior.Skill (SkillDir (..), SkillManifest (..), loadSkillManifest, skillRequestText)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Payload
import Shikigami.Execution.Policy
import Shikigami.Execution.Policy.Limits (policyNumber)
import Shikigami.Execution.SelectionRuntime (narrowOutput)
import Shikigami.Execution.ToolPosition
import Shikigami.Execution.Transcript
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Prelude
import Shikigami.StateRevision (advanceRevisions, initialRevision)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (runLLMWith)
import Shikumi.Tool (registryBaikai, registryTools, renderToolError, runErasedOutput, someToolName, someToolSchema)
import System.Timeout (timeout)

data EphemeralResult = EphemeralResult
  { output :: !Aeson.Value,
    modelCalls :: !Int,
    toolCalls :: !Int,
    recording :: !EphemeralRecording
  }
  deriving stock (Eq, Generic)

instance Show EphemeralResult where show _ = "EphemeralResult <protected>"

newtype EphemeralRecording = EphemeralRecording [Aeson.Value]
  deriving stock (Eq)

runEphemeralBehavior :: NominalDiffTime -> HarnessPolicy -> BehaviorEnv -> AgentDecl -> BehaviorInput -> IO (Either RunError EphemeralResult)
runEphemeralBehavior duration base env decl input = case narrowHarnessPolicy base decl.harness of
  Left reason -> pure (Left (HarnessPolicyRefused reason))
  Right policy
    | Set.fromList decl.capabilityOverlays /= env.activeOverlays || length decl.capabilityOverlays /= Set.size env.activeOverlays -> pure (Left (CapabilityOverlayMismatch decl.capabilityOverlays (Set.toAscList env.activeOverlays)))
    | otherwise -> case decl.behavior of
        Skill {path} -> do
          loaded <- loadSkillManifest (SkillDir (Text.unpack (declarationCoordinateText path)))
          case loaded of
            Left err -> pure (Left err)
            Right manifest -> loop [] policy 0 0 0 ModelTurn (ReplayContext RequestContext (Just manifest.description) [RequestTurn [TextBlock (skillRequestText manifest input)] Nothing]) Nothing
        _ -> fmap (\value -> EphemeralResult value 0 0 (EphemeralRecording [])) <$> runBehavior env decl input
  where
    tools = registryTools env.tools
    bindings = [ToolBinding (executionCoordinate (someToolName tool)) (executionCoordinate "ephemeral/1") (executionDigestFor "shikigami.tool-schema/1" (someToolSchema tool)) UncertainEffect UnreportedInvoiceCost | tool <- tools]
    micros = fromInteger (max 1 (min 3500000000 (ceiling (duration * 1000000))))
    refused = Left . HarnessPolicyRefused . boundedBehaviorDetail
    loop journal policy calls toolCount repairs kind source summary
      | length tools > 128 = pure (refused "offered tool menu exceeds its supported ceiling")
      | calls >= policyNumber policy.maxModelTurns = pure (Left (SkillToolTurnLimitExceeded (policyNumber policy.maxModelTurns)))
      | otherwise = case prepareModelOperationInput policy kind source Nothing summary of
          Left err -> pure (refused (Text.pack (show err)))
          Right (_, accepted) | not (withinPayload (toJSON accepted)) -> pure (refused "accepted model input exceeds the payload ceiling")
          Right (actualKind, accepted) -> case (restoreContext accepted.view.context, narrowOutput env.options (policyNumber <$> accepted.maxOutputTokens)) of
            (Right context, Right options) -> do
              let request = context & #tools .~ if actualKind == ModelSummary then Vector.empty else registryBaikai env.tools
              case validateResponseRequest env.model options request of
                Left err -> pure (Left (ProviderFailed Permanent (renderResponseCompatibilityError err)))
                Right () -> do
                  completed <- bounded (completeBehaviorRequest env env.model request options)
                  case completed of
                    Left err -> pure (Left err)
                    Right response -> case responseError response of
                      Just err -> pure (Left (ProviderFailed (failureClass (isRetryable err)) "ephemeral model call failed"))
                      Nothing -> do
                        let assistant = captureAssistant response
                            calls' = calls + 1
                            retained = toJSON assistant : toJSON accepted : journal
                            transcript = accepted.view.context & #messages %~ (<> [AssistantTurn assistant])
                        if not (withinPayload (toJSON assistant))
                          then pure (refused "model output exceeds the payload ceiling")
                          else
                            if actualKind == ModelSummary
                              then case validateTerminalOutput (policy & #output .~ NonemptyReply) assistant of
                                Left _ -> pure (refused "summary output is invalid")
                                Right _ -> do
                                  let execution = executionIdentity "ephemeral"
                                      position = advanceRevisions (fromIntegral calls) initialRevision
                                      specification = OperationSpec (operationIdFor execution position) ModelSummary RepeatableObservation (executionCoordinate "summary") (executionDigest "ephemeral") (executionDigest "ephemeral") Nothing
                                      reference value = do
                                        payloadId <- parsePayloadId "ephemeral"
                                        digest <- parsePayloadDigest (versionedDigest "shikigami.ephemeral-payload/1" value)
                                        bytes <- parsePayloadByteCount (fromIntegral (Lazy.length (Aeson.encode value)))
                                        pure (PayloadRef payloadId digest bytes)
                                  case (reference (toJSON accepted), reference (toJSON assistant)) of
                                    (Right input, Right output) -> do
                                      let operation = Operation V1 execution position specification (executionDigest "ephemeral") input (Just output) (Just NeedModel) NotMarkedUncertain Nothing
                                      loop retained policy calls' toolCount repairs kind source (Just (operation, accepted, assistant))
                                    _ -> pure (refused "ephemeral payload reference is invalid")
                              else
                                if assistant.stopReason == ToolUse
                                  then do
                                    observations <- runTools policy assistant
                                    case observations of
                                      Left err -> pure (Left err)
                                      Right messages -> loop (map toJSON messages <> retained) policy calls' (toolCount + length messages) repairs ModelTurn (transcript & #messages %~ (<> messages)) Nothing
                                  else case validateTerminalOutput policy assistant of
                                    Right output -> pure (Right (EphemeralResult output calls' toolCount (EphemeralRecording retained)))
                                    Left _ | repairs < policyNumber policy.outputRepairs -> loop retained policy calls' toolCount (repairs + 1) ModelRepair transcript Nothing
                                    Left _ -> pure (refused "accepted reply failed output validation")
            _ -> pure (refused "model context or output ceiling is unsupported")
    runTools policy assistant = go [] (zip [0 ..] (toolInvocations assistant))
      where
        go _ [] | null (toolInvocations assistant) = pure (refused "empty tool request")
        go accepted [] = pure (Right (reverse accepted))
        go accepted ((position, invocation) : remaining) = case either (Left . ExecutionPolicyRefused) (validateToolInvocation policy bindings bindings assistant) (parseToolPosition position) of
          Left err -> pure (refused (Text.pack (show err)))
          Right ToolNeedsPermission {} -> pure (refused "human permission requires shikigami-agent-run")
          Right (ToolAdmitted binding) -> case find ((== executionCoordinateText binding.name) . someToolName) tools of
            Nothing -> pure (refused "accepted tool is unavailable")
            Just tool -> do
              registry <- newProviderRegistryFrom []
              result <- bounded (runEff . runErrorNoCallStack @ShikumiError . runLLMWith registry $ runErasedOutput tool invocation.arguments)
              case result of
                Left err -> pure (Left err)
                Right (Left _) -> pure (refused "tool outcome is uncertain; no automatic retry")
                Right (Right value) -> do
                  let observation = either (\err -> ToolTurn invocation.callId invocation.name [TextBlock (renderToolError err)] ToolFailed Nothing) (\output -> let retained = captureToolOutput output in ToolTurn invocation.callId invocation.name (observationBlocks retained) retained.failed Nothing) value
                  if withinPayload (toJSON observation) then go (observation : accepted) remaining else pure (refused "tool output exceeds the payload ceiling")
    withinPayload value = Lazy.length (Aeson.encode value) <= 1048576
    bounded :: IO a -> IO (Either RunError a)
    bounded action = do
      result <- Exception.try @Exception.SomeException (timeout micros action)
      case result of
        Left err | isJust (Exception.fromException @Exception.SomeAsyncException err) -> Exception.throwIO err
        Left _ -> pure (refused "external outcome is uncertain; no automatic retry")
        Right Nothing -> pure (refused "external call exceeded its deadline; outcome is uncertain")
        Right (Just value) -> pure (Right value)
