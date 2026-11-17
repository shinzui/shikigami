-- | The agent-run workflow's own entries in the kernel action record
-- (EP-8 M3 of MasterPlan 22).
--
-- The workflow owns three kinds. @run.admitted@ says which declaration a
-- run pins (K4), what bounds its spending (K5), the key it was admitted on
-- (K8), what the directory said about its principal (K1) and where its
-- result goes. @run.finished@ closes the run. @output.delivered@ is the
-- effect of one delivered output: it names the exact action the authority
-- allowed for it and the journaled step it happened in, so
-- 'Shikigami.Record.Invariant.checkRun' can pair the effect with its
-- decision (K2, K3) and its step (K6).
--
-- Payloads carry bounded coordinates only: never the behavior's result, a
-- tool input or a credential.
module Shikigami.Agent.RunRecord
  ( admittedKind,
    finishedKind,
    deliveredKind,
    RunAdmission (..),
    admissionEntry,
    lifecycleLabel,
    declarationDigest,
    RunFinish (..),
    finishEntry,
    deliveredEntry,
  )
where

import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime)
import Shikigami.Agent.Decl (AgentDecl)
import Shikigami.Authority (Action, actionResource, actionTag)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Directory (Lifecycle (..), LifecycleDecision (..), PrincipalRecord (..))
import Shikigami.Output (ResolvedOutputs (..), resolvedOutputList)
import Shikigami.Output qualified as Output
import Shikigami.Record (RecordEntry, RecordError, RecordKind, mkRecordEntry, mkRecordKind)

admittedKind, finishedKind, deliveredKind :: RecordKind
admittedKind = known "run.admitted"
finishedKind = known "run.finished"
deliveredKind = known "output.delivered"

known :: Text -> RecordKind
known = either (error . Text.unpack) id . mkRecordKind

-- | What admission fixed for one run.
data RunAdmission = RunAdmission
  { -- | 'declarationDigest' of the journaled declaration.
    digest :: !Text,
    -- | How the run was started (@operator@, @schedule@, ...).
    trigger :: !Text,
    idempotencyKey :: !Text,
    -- | The resource root the run spends under, when it has one.
    root :: !(Maybe Text),
    -- | The run's lease: how long it may hold its instance before another
    -- process may resume it.
    timeout :: !NominalDiffTime,
    -- | 'lifecycleLabel' of the directory's answer for the run's identity.
    lifecycle :: !Text,
    outputs :: !ResolvedOutputs
  }

-- | The digest a run pins: @versionedDigest "shikigami.declaration/1"@ over
-- the declaration's journal JSON, which is the value the workflow executes.
declarationDigest :: AgentDecl -> Text
declarationDigest decl = versionedDigest "shikigami.declaration/1" (toJSON decl)

-- | @active@, @unmanaged@ (no directory record governs the identity),
-- @paused@ or @deactivated@ (the directory said to skip), @unknown@ or
-- @unavailable@.
lifecycleLabel :: LifecycleDecision -> Text
lifecycleLabel = \case
  AllowRun (Just _) -> "active"
  AllowRun Nothing -> "unmanaged"
  SkipRun PrincipalRecord {lifecycle = Deactivated} _ -> "deactivated"
  SkipRun _ _ -> "paused"
  UnknownPrincipal _ -> "unknown"
  DirectoryUnavailable _ -> "unavailable"

admissionEntry :: RunAdmission -> Either RecordError RecordEntry
admissionEntry RunAdmission {digest, trigger, idempotencyKey, root, timeout, lifecycle, outputs} =
  mkRecordEntry
    admittedKind
    ( object
        [ "declarationDigest" .= digest,
          "trigger" .= trigger,
          "idempotencyKey" .= idempotencyKey,
          "root" .= root,
          "timeoutSeconds" .= (floor timeout :: Integer),
          "lifecycle" .= lifecycle,
          "outputs" .= outputsValue outputs
        ]
    )

-- | Which outputs the run reports to, and whether the declaration listed
-- them or the composition supplied its default.
outputsValue :: ResolvedOutputs -> Value
outputsValue resolved =
  object
    [ "resolution" .= case resolved of
        DeclaredOutputs _ -> "declared" :: Text
        CompositionDefault _ -> "composition-default"
        JournalOnly -> "journal-only",
      "kinds" .= (Output.outputKindText . (.kind) <$> resolvedOutputList resolved)
    ]

-- | How a run ended.
data RunFinish
  = Finished
  | FinishedFailed !Text

finishEntry :: RunFinish -> Either RecordError RecordEntry
finishEntry = \case
  Finished -> mkRecordEntry finishedKind (object ["outcome" .= ("completed" :: Text)])
  FinishedFailed detail -> mkRecordEntry finishedKind (object ["outcome" .= ("failed" :: Text), "detail" .= Text.take 256 detail])

-- | The effect of one delivered output, after the authority allowed
-- @action@ in the step named here.
deliveredEntry :: Text -> Action -> Output.OutputReceipt -> Either RecordError RecordEntry
deliveredEntry step action Output.OutputReceipt {kind, location} =
  mkRecordEntry
    deliveredKind
    ( object
        [ "action" .= actionTag action,
          "resource" .= actionResource action,
          "step" .= step,
          "effectKey" .= actionResource action,
          "output" .= kind,
          "location" .= Text.take 512 location
        ]
    )
