module Shikigami.Agent.Command.RunBehavior
  ( runRunBehavior,
    profileRequirementRefusal,
  )
where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Text (encodeToLazyText)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Text.Lazy.IO qualified as TLIO
import Shikigami.Action.Authorization (denyAllActionAuthorizer)
import Shikigami.Agent.Capability.OneOff (renderOneOffCapabilityError, withOneOffCapabilityOverlays)
import Shikigami.Agent.Decl (AgentDecl (..), ProfileRequirement (..))
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Payload (readPayloadArgument)
import Shikigami.App.Config (AppConfig)
import Shikigami.App.Config qualified as Config
import Shikigami.Attestation.Profile (ProfileId (..))
import Shikigami.Behavior.Provider (newBehaviorEnvFor)
import Shikigami.Behavior.Run (triggerOnly)
import Shikigami.Duration
import Shikigami.Execution.Ephemeral (EphemeralResult (..), runEphemeralBehavior)
import Shikigami.Log qualified as Log
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | @run-behavior --agent <file> [--payload <json>]@: load a manifest, run its
-- behavior, and print the output JSON.
--
-- It opens no database and joins no queue, which makes it the cheapest way to
-- exercise a provider end to end: with @behavior.provider@ unset it prints the
-- stub's fixed sentence, and with the Anthropic branch configured it is a single
-- real model call. The provider line on standard error says which of those just
-- happened, so the two are never confused. That line is a structured
-- @behavior.provider.selected@ event on standard error; the command's own output
-- stays on standard out, so piping the result to @jq@ is unaffected.
runRunBehavior :: FilePath -> Maybe String -> Maybe FilePath -> AppConfig -> IO ()
runRunBehavior path mpayload workspace config = do
  logger <- Log.newStderrLogger Log.Info
  supplied <- readPayloadArgument mpayload
  payload <- case supplied of
    Nothing -> pure Aeson.Null
    Just raw -> case Aeson.decodeStrict (TE.encodeUtf8 (Text.pack raw)) of
      Just v -> pure v
      Nothing -> do
        hPutStrLn stderr "run-behavior: payload input is not valid JSON"
        exitFailure
  declE <- loadAgent path
  case declE of
    Left err -> do
      hPutStrLn stderr ("run-behavior: load error in " <> path <> ": " <> show err)
      exitFailure
    Right decl ->
      case profileRequirementRefusal decl of
        Just refusal -> do
          hPutStrLn stderr ("run-behavior: " <> Text.unpack refusal)
          exitFailure
        Nothing -> do
          env <- newBehaviorEnvFor logger ((.behaviorProvider) config) Nothing
          -- No recalled memories: recall needs a database and this command opens
          -- none, so the behavior runs on the trigger payload alone.
          Log.logInfo logger "execution.mode" ["mode" .= ("ephemeral" :: Text), "resumable" .= False]
          resultE <-
            withOneOffCapabilityOverlays logger denyAllActionAuthorizer workspace decl env \derivedEnv ->
              runEphemeralBehavior (durationTime config.runTimeout) config.harness derivedEnv decl (triggerOnly payload)
          case resultE of
            Left overlayErr -> do
              hPutStrLn stderr ("run-behavior: " <> Text.unpack (renderOneOffCapabilityError overlayErr))
              exitFailure
            Right (Left runErr) -> do
              hPutStrLn stderr ("run-behavior: " <> show runErr)
              exitFailure
            Right (Right result) -> do
              Log.logInfo logger "execution.ephemeral.completed" ["modelCalls" .= result.modelCalls, "toolCalls" .= result.toolCalls]
              TLIO.putStrLn (encodeToLazyText result.output)

-- | This command deliberately opens no database, so it cannot honestly run an
-- agent whose policy must first be resolved. Refuse before constructing the
-- behavior environment (and therefore before provider dispatch) and direct the
-- caller to the one-off command that does have the required store boundary.
profileRequirementRefusal :: AgentDecl -> Maybe Text
profileRequirementRefusal AgentDecl {sanctionedProfile} =
  case sanctionedProfile of
    Nothing -> Nothing
    Just ProfileRequirement {profileId} ->
      Just
        ( "agent requires sanctioned profile "
            <> profileId.value
            <> "; use shikigami-agent-run so it can resolve the profile before dispatch"
        )
