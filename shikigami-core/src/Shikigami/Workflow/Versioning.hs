-- | The one place Shikigami decides how a durable workflow run is configured.
--
-- A Keiro workflow journals its steps to Postgres and replays that journal
-- instead of re-running them, so an instance suspended before a deploy is
-- resumed by code that has since changed. 'Keiro.Workflow.patch' is what keeps
-- such an instance coherent: it journals a branch decision once and replays it
-- forever, so the instance stays on the code shape it started under while fresh
-- instances take the new one.
--
-- That mechanism only works if the deployed code says which patches are active,
-- and it says so through 'WorkflowRunOptions'. The plain
-- 'Keiro.Workflow.runWorkflow' entry point uses 'defaultWorkflowRunOptions',
-- whose @activePatches@ is empty — so a workflow run through it sees /every/
-- patch as 'False', including patches its own deploy introduced. Every durable
-- workflow run in this service therefore goes through the values below.
--
-- __This module is the only place Shikigami constructs 'WorkflowRunOptions'.__
-- A second options value built at a call site is a second answer to "which
-- patches are active", and the workflow that gets the wrong one silently takes
-- the wrong branch. New workflow run or resume options belong here too. Keep
-- their lease domains distinct: the PGMQ delivery heartbeat that
-- @docs\/plans\/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md@
-- needs uses @Keiro.PGMQ.JobContext.extendLease@; the Keiro resume worker
-- injects @WorkflowRunOptions.leaseHeartbeat@ itself and is configured through
-- @WorkflowResumeOptions.leaseTtl@. Direct runs leave @leaseHeartbeat@ unset.
--
-- The rules that govern when a change needs a patch at all are in
-- @docs\/workflow-versioning.md@.
module Shikigami.Workflow.Versioning
  ( shikigamiActivePatches,
    shikigamiWorkflowRunOptions,
    shikigamiWorkflowResumeOptions,
    terminalWorkflowRetention,
  )
where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Set (Set)
import Data.Time (NominalDiffTime)
import Keiro.Workflow (PatchId, WorkflowRunOptions (..), defaultWorkflowRunOptions)
import Keiro.Workflow.Gc (WorkflowGcPolicy (..))
import Keiro.Workflow.Resume (WorkflowResumeOptions (..), defaultWorkflowResumeOptions)
import Kioku.App (AppEnv (..))
import Shikigami.AgentRun.Generated.WorkflowRuntime qualified as AgentRun
import Shikigami.Approval.Generated.WorkflowRuntime qualified as Approval
import Shikigami.DanwaConversation.Generated.WorkflowRuntime qualified as DanwaConversation
import Shikigami.ExecutionDriver.Generated.WorkflowRuntime qualified as Execution

-- | Every patch id this deployment has active, read from the checked
-- specification rather than written here.
--
-- Each workflow's declared patch ids reach Haskell as @declaredPatches@ in its
-- generated @WorkflowRuntime@ module, scaffolded from
-- @domain\/shikigami-agent-run.keiro@ and @domain\/shikigami-conversation.keiro@.
-- Adding a patch id therefore means editing the specification, regenerating, and
-- passing @just keiro-gate@ — which is the discipline, not a description of it.
-- A hand-written list beside the generated one could drift from the gated one,
-- which is the precise failure this module exists to prevent.
--
-- The sets are unioned because Keiro's resume worker carries a single
-- 'WorkflowRunOptions' for every workflow it drives (@runOptions@ in
-- 'WorkflowResumeOptions'), so there is no boundary at which a per-workflow set
-- could be applied. Activating a patch id for a workflow that never calls
-- 'Keiro.Workflow.patch' with it is inert; it costs one extra entry in that
-- instance's reserved @__workflow_patches__@ record.
shikigamiActivePatches :: Set PatchId
shikigamiActivePatches =
  AgentRun.declaredPatches
    <> Approval.declaredPatches
    <> DanwaConversation.declaredPatches
    <> Execution.declaredPatches

-- | The options every first run of a Shikigami workflow uses.
shikigamiWorkflowRunOptions :: AppEnv -> WorkflowRunOptions
shikigamiWorkflowRunOptions AppEnv {tracer = appTracer, metrics = appMetrics} =
  defaultWorkflowRunOptions
    & #activePatches .~ shikigamiActivePatches
    & #tracer .~ Just appTracer
    & #metrics .~ appMetrics

-- | The options the resume worker uses, carrying 'shikigamiWorkflowRunOptions'
-- so a resumed run is configured exactly as its first run was.
shikigamiWorkflowResumeOptions :: AppEnv -> NominalDiffTime -> WorkflowResumeOptions
shikigamiWorkflowResumeOptions appEnv timeout =
  defaultWorkflowResumeOptions
    & #runOptions .~ shikigamiWorkflowRunOptions appEnv
    & #leaseTtl .~ (timeout + 30)
    & #maxConcurrentAdvances .~ 1

-- | Keep terminal workflow journals for ninety days. This bounds the workflow
-- idempotency window; redelivery older than that requires operator review.
-- Keiro excludes live instances and completed children of live parents.
-- Evidence streams/rows and sink receipts have separate ownership and survive.
terminalWorkflowRetention :: WorkflowGcPolicy
terminalWorkflowRetention = WorkflowGcPolicy {retention = 90 * 86400, batchSize = 100}
