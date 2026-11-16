-- | Everything a flow body and a pack value may import (docs/adr/0129).
--
-- This module is the whole of @shikigami-core:flow-sdk@ beside
-- "Shikigami.Flow.Sdk.Program". A pack's @bodies@ sublibrary depends on that
-- component and on no other Shikigami component, so the compiler holds a flow
-- body to this list: there is no 'Effectful.IOE' and no store here, and a body
-- that reaches for either does not build.
--
-- The export list is pinned by a golden file. Adding a name is a reviewed
-- change, made for a consumer that exists.
module Shikigami.Flow.Sdk
  ( -- * Packs
    FlowPack (..),
    PackFlow (..),
    kernelCapabilityFlow,
    FlowPackName,
    FlowPackNameError (..),
    parseFlowPackName,
    flowPackNameText,
    TriggerHooks (..),
    noTriggerHooks,

    -- * Flow declarations
    FlowDef (..),
    DecisionMode (..),
    FlowEffects,
    LifecycleDiagram (..),
    DefaultModelRequirement (..),
    DeclarationCoordinate,
    declarationCoordinate,
    declarationCoordinateText,

    -- * Writing a body
    Eff,
    (:>),
    Workflow,
    step,
    StepName (..),

    -- * Defining a pack capability
    Effect,
    Dispatch (..),
    DispatchOf,
    send,

    -- * Kernel capabilities
    Memory,
    MemoryQuery (..),
    recall,
    remember,
    SinkCapability,
    emitSignal,
    emitSignalTo,
    emitSignals,
    DecisionAbort (..),
    Activity,
    currentActivity,
    Acknowledgement,
    Ack (..),
    awaitAck,
    awaitAckWithin,
    Delegate,
    delegate,
    awaitOne,

    -- * The declaration vocabulary those capabilities take
    Sink (..),
    SinkResult (..),
    SinkOutcome (..),
    SinkMessageId,
    parseSinkSession,
    Priority (..),
    SignalType (..),
    RecipientFrom (..),
    SignalImportance,
    parseSignalImportance,
    ApprovalRequest (..),
    ApprovalChannel (..),
    ActivityEnvelope (..),
    Subject (..),
    ActivityCoordinate,
    activityCoordinate,
    activityCoordinateText,
  )
where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Keiro.Workflow (StepName (..), Workflow, step)
import Shikigami.Activity (ActivityEnvelope (..), Subject (..))
import Shikigami.Activity.Coordinate (ActivityCoordinate, activityCoordinate, activityCoordinateText)
import Shikigami.Agent.Approval (ApprovalChannel (..), ApprovalRequest (..))
import Shikigami.Agent.Decl (Priority (..), RecipientFrom (..), SignalType (..), Sink (..))
import Shikigami.Agent.DeclarationValue (DeclarationCoordinate, SignalImportance, declarationCoordinate, declarationCoordinateText, parseSignalImportance)
import Shikigami.Flow (DecisionMode (..), FlowDef (..), FlowEffects, LifecycleDiagram (..))
import Shikigami.Flow.Acknowledgement (Ack (..), Acknowledgement, awaitAck, awaitAckWithin)
import Shikigami.Flow.Capability (Activity, Memory, MemoryQuery (..), currentActivity, emitSignal, emitSignalTo, emitSignals, recall, remember)
import Shikigami.Flow.Capability qualified as Capability
import Shikigami.Flow.Delegate (Delegate, awaitOne, delegate)
import Shikigami.Flow.Pack (FlowPack (..), FlowPackName, FlowPackNameError (..), PackFlow (..), TriggerHooks (..), flowPackNameText, kernelCapabilityFlow, noTriggerHooks, parseFlowPackName)
import Shikigami.Program.DecisionRunner (DecisionAbort (..))
import Shikigami.RuntimePolicy (DefaultModelRequirement (..))
import Shikigami.Sink.Coordinate (parseSinkSession)
import Shikigami.Sink.Delivery (SinkMessageId)
import Shikigami.Sink.Types (SinkOutcome (..), SinkResult (..))

-- | The capability that emits through a declared sink. It is named apart from
-- the 'Sink' declaration it takes, which a body constructs by its
-- constructors; inside the kernel the two share a name across modules.
type SinkCapability = Capability.Sink
