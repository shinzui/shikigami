{-# LANGUAGE DataKinds #-}

-- | Dispatch one output through the real Kikan adapters, as the run that
-- enqueues it and the publisher that delivers it would (plan 135, M3).
--
-- 'dispatchOutput' computes the adapter's address from the trigger activity
-- and the result, then runs the publisher's gates and the adapter's dispatch.
-- Tests vary one field of 'DispatchContext' from 'dispatchContext'.
module Shikigami.Fixture.OutboxDispatch
  ( DispatchContext (..),
    dispatchContext,
    unreachableServices,
    withServices,
    withAgent,
    withIdentity,
    withGrants,
    withActivity,
    withTraceHeaders,
    deliveryFor,
    dispatchOutput,
    dispatchAddressed,
  )
where

import Data.Aeson (Value (Null))
import Data.List (find)
import Data.Text (Text)
import Data.Time (UTCTime)
import Kioku.Id (SessionId)
import Network.HTTP.Types.Header (Header)
import Shikigami.Activity (ActivityEnvelope)
import Shikigami.Activity.Coordinate (activityCoordinate)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity, compatibilityIdentity)
import Shikigami.Directory (DirectoryHandle, disabledDirectoryHandle)
import Shikigami.Fixture.SinkHttp (testSinkHttp)
import Shikigami.Log (Logger)
import Shikigami.Log qualified as Log
import Shikigami.Output (OutputAdapter (..), OutputDecl (..), outboxRouteOf)
import Shikigami.Output.Kikan (KikanServices (..), kikanOutputAdapters)
import Shikigami.Sink (GrantSource (StaticGrants), defaultGrantTable, dispatchOutbox)
import Shikigami.Sink.Config (DanwaConfig (..), KanmonConfig (..), KawaConfig (..), KizashiConfig (..), ReiConfig (..))
import Shikigami.Sink.Coordinate (SinkOrdinal, parseSinkSession, zeroSinkOrdinal)
import Shikigami.Sink.Types (AddressInput (..), DeliveryGuard, OutboxDelivery (..), OutboxRoute (..), SinkResult)

data DispatchContext = DispatchContext
  { services :: !KikanServices,
    agent :: !AgentName,
    identity :: !AgentIdentity,
    directory :: !DirectoryHandle,
    grants :: !GrantSource,
    runId :: !SessionId,
    ordinal :: !SinkOrdinal,
    occurredAt :: !(Maybe UTCTime),
    activity :: !(Maybe ActivityEnvelope),
    traceHeaders :: ![Header],
    receipts :: !(Maybe DeliveryGuard),
    logger :: !Logger
  }

-- | @heartbeat@, statically granted the outputs the sample agents use, with
-- every service unreachable.
dispatchContext :: DispatchContext
dispatchContext =
  DispatchContext
    { services = unreachableServices,
      agent = heartbeat,
      identity = compatibilityIdentity heartbeat,
      directory = disabledDirectoryHandle,
      grants = StaticGrants defaultGrantTable,
      runId = either (error . show) id (parseSinkSession "kioku_session_01kvxa7d2cezhs874g3n8dfgme"),
      ordinal = zeroSinkOrdinal,
      occurredAt = Nothing,
      activity = Nothing,
      traceHeaders = [],
      receipts = Nothing,
      logger = Log.silentLogger
    }
  where
    heartbeat = either (error . show) id (mkAgentName "heartbeat")

-- | Port 1 is not listening; a case that accidentally reaches a service fails
-- loudly rather than quietly succeeding against a real one.
unreachableServices :: KikanServices
unreachableServices =
  KikanServices
    { http = testSinkHttp,
      kizashi = KizashiConfig {baseUrl = unreachable, defaultRecipient = declarationCoordinate "recipient_default"},
      kawa = KawaConfig {baseUrl = unreachable, sourceSegment = activityCoordinate "shinzui/shikigami"},
      kanmon = KanmonConfig {baseUrl = unreachable},
      danwa = DanwaConfig {baseUrl = unreachable, agentParticipant = declarationCoordinate "part_agent_test"},
      rei = ReiConfig {baseUrl = Nothing}
    }
  where
    unreachable = "http://localhost:1" :: Text

withServices :: (KikanServices -> KikanServices) -> DispatchContext -> DispatchContext
withServices change DispatchContext {services, agent, identity, directory, grants, runId, ordinal, occurredAt, activity, traceHeaders, receipts, logger} =
  DispatchContext {services = change services, agent, identity, directory, grants, runId, ordinal, occurredAt, activity, traceHeaders, receipts, logger}

-- | Act as a compatibility identity of this agent.
withAgent :: AgentName -> DispatchContext -> DispatchContext
withAgent name context = case withIdentity (compatibilityIdentity name) context of
  DispatchContext {services, identity, directory, grants, runId, ordinal, occurredAt, activity, traceHeaders, receipts, logger} ->
    DispatchContext {services, agent = name, identity, directory, grants, runId, ordinal, occurredAt, activity, traceHeaders, receipts, logger}

withIdentity :: AgentIdentity -> DispatchContext -> DispatchContext
withIdentity value DispatchContext {services, agent, directory, grants, runId, ordinal, occurredAt, activity, traceHeaders, receipts, logger} =
  DispatchContext {services, agent, identity = value, directory, grants, runId, ordinal, occurredAt, activity, traceHeaders, receipts, logger}

withGrants :: GrantSource -> DispatchContext -> DispatchContext
withGrants value DispatchContext {services, agent, identity, directory, runId, ordinal, occurredAt, activity, traceHeaders, receipts, logger} =
  DispatchContext {services, agent, identity, directory, grants = value, runId, ordinal, occurredAt, activity, traceHeaders, receipts, logger}

withActivity :: ActivityEnvelope -> DispatchContext -> DispatchContext
withActivity value DispatchContext {services, agent, identity, directory, grants, runId, ordinal, occurredAt, traceHeaders, receipts, logger} =
  DispatchContext {services, agent, identity, directory, grants, runId, ordinal, occurredAt, activity = Just value, traceHeaders, receipts, logger}

withTraceHeaders :: [Header] -> DispatchContext -> DispatchContext
withTraceHeaders value DispatchContext {services, agent, identity, directory, grants, runId, ordinal, occurredAt, activity, receipts, logger} =
  DispatchContext {services, agent, identity, directory, grants, runId, ordinal, occurredAt, activity, traceHeaders = value, receipts, logger}

-- | The delivery the publisher would hand the adapter, with no address.
deliveryFor :: DispatchContext -> OutputDecl -> Value -> OutboxDelivery
deliveryFor DispatchContext {agent, identity, runId, ordinal, occurredAt, traceHeaders, receipts, logger} output result =
  OutboxDelivery {identity, agent, runId, ordinal, occurredAt, kind = output.kind, config = output.config, address = Null, result, traceHeaders, receipts, logger}

-- | Address the output from the context's activity and the result, then
-- dispatch it.
dispatchOutput :: DispatchContext -> OutputDecl -> Value -> IO SinkResult
dispatchOutput context output result =
  let route = routeFor context output
   in dispatchAddressed context output (route.address AddressInput {config = output.config, activity = context.activity, result}) result

-- | Dispatch with the address a test states.
dispatchAddressed :: DispatchContext -> OutputDecl -> Value -> Value -> IO SinkResult
dispatchAddressed context@DispatchContext {agent, identity, runId, ordinal, occurredAt, traceHeaders, receipts, logger} output address result =
  dispatchOutbox
    context.directory
    context.grants
    (routeFor context output)
    OutboxDelivery {identity, agent, runId, ordinal, occurredAt, kind = output.kind, config = output.config, address, result, traceHeaders, receipts, logger}

routeFor :: DispatchContext -> OutputDecl -> OutboxRoute
routeFor context output =
  case find (\adapter -> adapter.kind == output.kind) (kikanOutputAdapters context.services) >>= outboxRouteOf of
    Just route -> route
    Nothing -> error "Shikigami.Fixture.OutboxDispatch: not a Kikan output kind"
