-- | A dedicated admitted coordination tool, separate from mutation overlays.
-- Its pinned revision identifies the retained scope. Model arguments cannot
-- supply an actor, root, scope grant or durable operation key.
module Shikigami.WorkerSession.Tools (coordinationTools, appendNativeFactory, coordinatorRunFor) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Effectful (Eff)
import Effectful.Dispatch.Static (unsafeEff_)
import Keiro.Workflow.Types (WorkflowId (..))
import Shikigami.Action.Authorization (ActionAuthorizer)
import Shikigami.App (AppEffects, runAppIO)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Coordinate
import Shikigami.Execution.Executor (BoundTool (..))
import Shikigami.Execution.Policy.Types (RecoveryClass (IdempotentEffect), ToolInvoiceCost (NoInvoiceCost))
import Shikigami.Execution.Runner (OperationContext (..))
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.Tools (NativeToolFactory (..))
import Shikigami.Execution.Transcript (ExecutionError (..), ExecutionSnapshot (..), ToolBinding (..))
import Shikigami.Prelude hiding ((.=))
import Shikigami.WorkerSession.Capability
import Shikigami.WorkerSession.Handoff (TransferServices (..))
import Shikigami.WorkerSession.Workflow (SessionRuntime (..))
import Shikumi.Tool (SomeTool (..), ToolError (..))
import Shikumi.Tool.Output (ToolOutput (..), textToolOutput)

coordinatorRunFor :: ExecutionSnapshot -> CoordinatorRun
coordinatorRunFor snapshot = CoordinatorRun snapshot.runId snapshot.identity snapshot.sessionId snapshot.selection.rootId (Just snapshot.selection.permittedAliases)

coordinationTools :: Maybe CoordinationHost -> ActionAuthorizer -> NativeToolFactory
coordinationTools Nothing _ = NativeToolFactory (\_ -> pure (Right [])) (\_ _ _ -> pure (Right []))
coordinationTools (Just host) authorizer =
  NativeToolFactory
    { describe = \snapshot -> do
        granted <- owned (resolveGrant host authorizer (coordinatorRunFor snapshot) Nothing)
        pure (fmap (maybe [] (\grant -> [bound grant Nothing False | grantSupportsSkill grant])) granted),
      prepare = \snapshot context requested ->
        if maybe False (/= executionCoordinate name) requested
          then pure (Right [])
          else case filter ((== executionCoordinate name) . (.name)) snapshot.toolBindings of
            [] -> pure (Right [])
            [binding] -> case executionDigest <$> Text.stripPrefix prefix (executionCoordinateText binding.revision) of
              Nothing -> pure (Left (ExecutionPolicyRefused "unsupported coordination binding"))
              Just pinned -> do
                granted <- owned (resolveGrant host authorizer (coordinatorRunFor snapshot) (Just pinned))
                pure do
                  permit <- granted >>= maybe (Left (ExecutionPolicyRefused "pinned coordination scope unavailable")) Right
                  unless (grantSupportsSkill permit) (Left (ExecutionPolicyRefused "scope does not admit Skill coordination"))
                  let legacy = binding.schemaDigest == executionDigestFor "shikigami.tool-schema/1" legacySchema
                      tool = bound permit (Just context) legacy
                  unless (tool.binding == binding) (Left (ExecutionPolicyRefused "coordination binding changed"))
                  pure [tool]
            _ -> pure (Left (ExecutionPolicyRefused "ambiguous coordination binding"))
    }
  where
    name = "workers"
    prefix = "worker-coordination/1:"
    owned :: Eff AppEffects (Either e a) -> IO (Either ExecutionError a)
    owned action =
      runAppIO host.services.sessions.appEnv action <&> \case
        Right (Right result) -> Right result
        _ -> Left (ExecutionPolicyRefused "admitted coordination authority unavailable")
    bound grant context legacy =
      let selectedSchema = if legacy then legacySchema else schema
       in BoundTool
            (ToolBinding (executionCoordinate name) (executionCoordinate (prefix <> executionDigestText (grantFingerprint grant))) (executionDigestFor "shikigami.tool-schema/1" selectedSchema) IdempotentEffect NoInvoiceCost)
            ( DynTool name "Control only the continuing workers admitted for this assignment. Stable operation identity is supplied by the durable harness. Results contain bounded metadata and accepted findings." selectedSchema \arguments ->
                case (context, Aeson.fromJSON arguments) of
                  (Nothing, _) -> pure (Left (ToolRunFailed name "description does not authorize execution"))
                  (_, Aeson.Error _) -> pure (Left (ToolArgsInvalid name "invalid closed worker command"))
                  (Just _, Aeson.Success ReconcileWorkerCheckpoint {}) | legacy -> pure (Left (ToolArgsInvalid name "checkpoint reconciliation is outside this accepted binding"))
                  (Just accepted, Aeson.Success command) -> do
                    result <- unsafeEff_ (runAppIO host.services.sessions.appEnv (executeCommand host authorizer grant accepted.operationId command))
                    pure case result of
                      Right response ->
                        let value = toJSON response
                            output = textToolOutput (Text.decodeUtf8 (Lazy.toStrict (Aeson.encode value)))
                         in -- The public upstream ToolOutput has no Generic instance.
                            Right (output {structuredContent = Just value})
                      Left _ -> Left (ToolRunFailed name "worker command store unavailable")
            )

appendNativeFactory :: NativeToolFactory -> NativeToolFactory -> NativeToolFactory
appendNativeFactory base extra =
  NativeToolFactory
    { describe = \snapshot -> do
        left <- base.describe snapshot
        right <- extra.describe snapshot
        pure ((<>) <$> left <*> right),
      prepare = \snapshot context requested -> do
        left <- base.prepare snapshot context requested
        right <- extra.prepare snapshot context requested
        pure ((<>) <$> left <*> right)
    }

-- A closed top-level envelope; the typed decoder also rejects unknown fields.
legacySchema :: Aeson.Value
legacySchema =
  Aeson.object
    [ "type" .= ("object" :: Text),
      "additionalProperties" .= False,
      "properties"
        .= Aeson.object
          [ "tag" .= Aeson.object ["type" .= ("string" :: Text), "enum" .= (["FindWorker", "SendWorker", "InspectWorker", "ReadWorkerEvents", "ReadWorkerResult", "InterruptWorker", "CancelWorker", "TransferWorker", "ReconcileWorker", "IntegrateWorkerEvents"] :: [Text])],
            "workerKey" .= string,
            "sessionId" .= string,
            "expectedRevision" .= integer,
            "epoch" .= integer,
            "instruction" .= Aeson.object ["type" .= ("object" :: Text), "description" .= ("text, objectiveRevision, assignmentRevision, criteriaRevision, selection (null or declared alias requirements). Actor, operation, kind and root are supplied by the runtime." :: Text)],
            "assignmentId" .= string,
            "after" .= integer,
            "limit" .= integer,
            "workspace" .= Aeson.object ["type" .= ("object" :: Text), "description" .= ("operator-owned provider and resource identities" :: Text)],
            "target" .= string
          ],
      "required" .= (["tag"] :: [Text])
    ]
  where
    string = Aeson.object ["type" .= ("string" :: Text)]
    integer = Aeson.object ["type" .= ("integer" :: Text)]

-- Fresh bindings expose the additive command; preparation retains the exact
-- old schema and command set for executions admitted before this addition.
schema :: Aeson.Value
schema = case legacySchema of
  Aeson.Object fields -> case KeyMap.lookup "properties" fields of
    Just (Aeson.Object properties) ->
      let tags = ["FindWorker", "SendWorker", "InspectWorker", "ReadWorkerEvents", "ReadWorkerResult", "InterruptWorker", "CancelWorker", "TransferWorker", "ReconcileWorker", "IntegrateWorkerEvents", "ReconcileWorkerCheckpoint"] :: [Text]
          tag = Aeson.object ["type" .= ("string" :: Text), "enum" .= tags]
          revalidation = Aeson.object ["type" .= ("object" :: Text), "additionalProperties" .= False, "properties" .= Aeson.object ["objectiveRevision" .= integer, "assignmentRevision" .= integer, "criteriaRevision" .= integer, "statement" .= string], "required" .= (["objectiveRevision", "assignmentRevision", "criteriaRevision", "statement"] :: [Text])]
          next = KeyMap.insert "tag" tag (KeyMap.insert "previousOperation" string (KeyMap.insert "revalidation" revalidation properties))
       in Aeson.Object (KeyMap.insert "properties" (Aeson.Object next) fields)
    _ -> legacySchema
  _ -> legacySchema
  where
    string = Aeson.object ["type" .= ("string" :: Text)]
    integer = Aeson.object ["type" .= ("integer" :: Text)]
