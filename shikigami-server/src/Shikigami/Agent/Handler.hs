-- | Catalog reads against the process's declarations and lifecycle snapshot.
module Shikigami.Agent.Handler (agentServer, agentView, agentSort) where

import Data.Map.Strict qualified as Map
import Relay.Pagination (CursorPayload (..), Direction (..), KeyValue (..), PageRequest (..), decodeCursor)
import Relay.Pagination.Hasql.Connection (mkConnection)
import Relay.Pagination.Hasql.KeyCodec (textKey)
import Relay.Pagination.Hasql.SortSpec
import Servant.Server.Generic (AsServerT)
import Shikigami.Agent.Api
import Shikigami.Agent.Catalog qualified as Catalog
import Shikigami.Agent.Decl qualified as Decl
import Shikigami.Api.Problem
import Shikigami.Directory qualified as Directory
import Shikigami.Prelude
import Shikigami.Server.Seam

agentSort :: SortSpec AgentView
agentSort = SortSpec (KeyColumn "agents.name" Asc (.name) textKey :| [])

agentServer :: ServerEnv -> AgentApi (AsServerT ServerM)
agentServer env = AgentApi {list = listAgents, show = showAgent}
  where
    showAgent name = case Catalog.lookupAgent env.catalog name of
      Nothing -> pure (AgentMissing (problem AgentNotFound "No declared agent has this name."))
      Just decl ->
        liftIO (directoryAvailable env) >>= \case
          False -> pure (AgentUnavailable unavailable)
          True -> AgentFound <$> liftIO (agentView env decl)
    listAgents request
      | request.pageSize == 0 = pure (AgentPageInvalid invalid)
      | otherwise = case traverse (decodeCursor (sortSpecFingerprint agentSort)) request.cursor of
          Left _ -> pure (AgentPageInvalid invalid)
          Right payload -> case traverse cursorName payload of
            Nothing -> pure (AgentPageInvalid invalid)
            Just boundary ->
              liftIO (directoryAvailable env) >>= \case
                False -> pure (AgentPageUnavailable unavailable)
                True -> do
                  views <- liftIO (traverse (agentView env) (Map.elems env.catalog.declarations))
                  let eligible = filter (within request.direction boundary) views
                      ordered = case request.direction of Forward -> eligible; Backward -> reverse eligible
                  pure (AgentPage (mkConnection agentSort request (take (request.pageSize + 1) ordered)))
    cursorName payload = case payload.keys of [KvText name] -> Just name; _ -> Nothing
    within _ Nothing _ = True
    within Forward (Just name) row = row.name > name
    within Backward (Just name) row = row.name < name
    invalid = problem InvalidUrl "Use a positive page size and a cursor issued by this route."
    unavailable = problem Unavailable "The lifecycle directory is unavailable."

directoryAvailable :: ServerEnv -> IO Bool
directoryAvailable env =
  Directory.readDirectorySnapshot env.directory <&> \case
    Directory.DirectoryUnavailableSnapshot {} -> False
    _ -> True

agentView :: ServerEnv -> Decl.AgentDecl -> IO AgentView
agentView env decl = do
  snapshot <- Directory.readDirectorySnapshot env.directory
  let configured = case snapshot of Directory.DirectoryDisabledSnapshot {} -> False; _ -> True
  lifecycle <- Catalog.agentLifecycle configured env.directory decl
  pure
    AgentView
      { name = decl.name,
        description = decl.description,
        enabled = decl.enabled,
        trigger = case decl.trigger of
          Decl.Schedule {} -> "schedule"
          Decl.Stream {} -> "stream"
          Decl.Event {} -> "event",
        behavior = case decl.behavior of
          Decl.Deterministic {} -> "deterministic"
          Decl.ShikumiProgram {} -> "shikumi_program"
          Decl.Skill {} -> "skill"
          Decl.Flow {} -> "flow",
        sinks = fmap sinkKind decl.sinks,
        delegates = decl.delegates,
        principalId = (.principal) <$> decl.identity,
        lifecycle = case lifecycle of
          Catalog.LifecycleActive -> "active"
          Catalog.LifecyclePaused -> "paused"
          Catalog.LifecycleDeactivated -> "deactivated"
          Catalog.LifecycleUnknown -> "unknown"
          Catalog.LifecycleUnverified -> "unverified",
        runnable = Catalog.runnable decl lifecycle
      }
  where
    sinkKind = \case
      Decl.KawaDigest {} -> "kawa_digest"
      Decl.KizashiSignal {} -> "kizashi_signal"
      Decl.ReiAction {} -> "rei_action"
      Decl.DanwaConversation {} -> "danwa_conversation"
      Decl.ChannelEgress {} -> "channel_egress"
