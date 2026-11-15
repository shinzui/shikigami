{-# LANGUAGE DataKinds #-}

-- | The durable playbook interpreter (EP-4 M2 of MasterPlan 22).
--
-- A pinned 'Bundle' runs as a flow body: it holds only the flow
-- capabilities, so every effect is a keyed child workflow whose journal a
-- replay reads. A step's key is its path in the bundle (for example
-- @each-repository.1.improve@), so a restarted run finds its completed
-- coding-agent steps and its pending approval instead of repeating them.
-- Items run one at a time; the first step that does not succeed ends the run.
module Shikigami.Playbook.Run
  ( PlaybookAgent (..),
    runPlaybook,
    payloadParameters,
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, (:>))
import Keiro.Workflow (StepName (..))
import Shikigami.Agent.Approval (ApprovalChannel (..), ApprovalRequest (..))
import Shikigami.Capability.Declared (mkToolName)
import Shikigami.CodingAgent.Types
import Shikigami.DeclaredTool.Workflow (ToolRun (..), ToolStepOutcome (..), mkToolStep, renderToolStepOutcome, toolStepOutcomeLabel)
import Shikigami.Flow.Acknowledgement (Ack (Acknowledged, Declined), Acknowledgement, awaitAck)
import Shikigami.Flow.Acknowledgement qualified as Ack
import Shikigami.Flow.CodingAgent (CodingAgent, codingAgentKey, runCodingAgentStep, runCodingAgentStepIn)
import Shikigami.Flow.DeclaredTool (DeclaredTool, runDeclaredTool, toolStepKey)
import Shikigami.Playbook

-- | What the declaration fixes for the bundle's coding-agent steps.
data PlaybookAgent = PlaybookAgent
  { provider :: !CodingAgentProvider,
    access :: !WorkspaceAccess,
    model :: !(Maybe VendorModelId),
    effort :: !(Maybe CodingAgentEffort)
  }

data StepResult = StepResult {key :: !Text, outcome :: !Text, summary :: !Text}

-- | The top-level string fields of the payload: the run parameters.
payloadParameters :: Value -> Map Text Text
payloadParameters = \case
  Object fields -> Map.fromList [(Key.toText name, value) | (name, String value) <- KeyMap.toList fields]
  _ -> Map.empty

runPlaybook ::
  (CodingAgent :> es, DeclaredTool :> es, Acknowledgement :> es) =>
  PlaybookAgent ->
  Bundle ->
  Value ->
  Eff es Value
runPlaybook agent bundle payload = do
  (results, stopped) <- case lookupPlaybook bundle bundle.main of
    Nothing -> pure ([], Just "the main playbook is missing")
    Just root -> runSteps agent bundle payload (payloadParameters payload) Map.empty "" root.steps
  let outcome = maybe "completed" (const "stopped") stopped
  pure
    ( object
        [ "outcome" .= (outcome :: Text),
          "summary" .= maybe ("playbook " <> bundle.main <> " completed " <> Text.pack (show (length results)) <> " steps") id stopped,
          "steps" .= [object ["key" .= key, "outcome" .= outcome', "summary" .= summary] | StepResult {key, outcome = outcome', summary} <- results]
        ]
    )

-- | Run steps in order; the second component names why the run stopped.
runSteps ::
  (CodingAgent :> es, DeclaredTool :> es, Acknowledgement :> es) =>
  PlaybookAgent ->
  Bundle ->
  Value ->
  Map Text Text ->
  Map Text Text ->
  Text ->
  [PlaybookStep] ->
  Eff es ([StepResult], Maybe Text)
runSteps agent bundle payload parameters variables prefix = go []
  where
    go done = \case
      [] -> pure (reverse done, Nothing)
      current : rest -> do
        (results, stopped) <- runOne current
        let done' = reverse results <> done
        case stopped of
          Just reason -> pure (reverse done', Just reason)
          Nothing -> go done' rest
    render = renderTemplate parameters variables
    runOne current =
      let key = prefix <> stepId current
       in case current of
            CodingAgent {prompt, workspace, deadlineMinutes} ->
              case (,) <$> mkCodingAgentPrompt (render prompt) <*> mkDeadlineMinutes deadlineMinutes of
                Left problem -> pure ([StepResult key "refused" problem], Just (key <> ": " <> problem))
                Right (stepPrompt, deadline) -> do
                  let requested = CodingAgentStep {provider = agent.provider, prompt = stepPrompt, access = agent.access, model = agent.model, effort = agent.effort, deadlineMinutes = deadline, skills = []}
                      target = render workspace
                  outcome <-
                    if Text.null target
                      then runCodingAgentStep (codingAgentKey key) requested payload
                      else runCodingAgentStepIn target (codingAgentKey key) requested payload
                  let result = StepResult key (outcomeLabel outcome) (renderOutcome outcome)
                  pure case outcome of
                    Completed _ -> ([result], Nothing)
                    _ -> ([result], Just (key <> ": " <> renderOutcome outcome))
            Tool {tool, args, deadlineMinutes} ->
              case mkToolName tool >>= \name -> mkToolStep name (render <$> args) deadlineMinutes of
                Left problem -> pure ([StepResult key "refused" problem], Just (key <> ": " <> problem))
                Right requested -> do
                  outcome <- runDeclaredTool (toolStepKey key) requested
                  let result = StepResult key (toolStepOutcomeLabel outcome) (renderToolStepOutcome outcome)
                  pure case outcome of
                    ToolCompleted ToolRun {exit = 0} -> ([result], Nothing)
                    _ -> ([result], Just (key <> ": " <> renderToolStepOutcome outcome))
            Approval {prompt} -> do
              ack <- awaitAck (StepName ("playbook-" <> key)) ApprovalRequest {prompt = render prompt, context = object ["step" .= key, "playbook" .= bundle.main], channel = ViaLocalInbox}
              pure case ack of
                Acknowledged _ -> ([StepResult key "approved" "approved"], Nothing)
                Declined reason -> ([StepResult key "declined" reason], Just (key <> ": declined" <> (if Text.null reason then "" else " (" <> reason <> ")")))
                Ack.TimedOut -> ([StepResult key "timed_out" "no answer before the deadline"], Just (key <> ": no answer before the deadline"))
            RunPlaybook {playbook} -> nested key playbook variables
            ForEach {items, item, playbook} -> each key playbook item (itemValues items) []
    nested key name scope = case lookupPlaybook bundle name of
      Nothing -> pure ([StepResult key "refused" ("no playbook " <> name)], Just (key <> ": no playbook " <> name))
      Just child -> runSteps agent bundle payload parameters scope (key <> ".") child.steps
    each _ _ _ [] done = pure (done, Nothing)
    each key name variable ((index, value) : rest) done = do
      (results, stopped) <- nested (key <> "." <> Text.pack (show (index :: Int))) name (Map.insert variable value variables)
      case stopped of
        Just reason -> pure (done <> results, Just reason)
        Nothing -> each key name variable rest (done <> results)
    itemValues =
      zip [0 ..] . \case
        Literal values -> values
        FromPayload field -> case payload of
          Object fields | Just (Array values) <- KeyMap.lookup (Key.fromText field) fields -> mapMaybe asText (toList values)
          _ -> []
    asText = \case
      String value -> Just value
      _ -> Nothing
