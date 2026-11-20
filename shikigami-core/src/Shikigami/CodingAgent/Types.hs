-- | The vocabulary of a durable coding-agent step (EP-2 of MasterPlan 22).
--
-- A step asks a vendor coding tool (Claude Code or Codex) to do one task in
-- the run's worktree, unattended, under an absolute deadline. Its outcome is a
-- journaled summary: the full envelope, evidence and captured streams stay in
-- the attempt directory, referenced by path and digest. Checked values keep
-- private constructors and re-check on decode (ADR-80).
module Shikigami.CodingAgent.Types
  ( -- * The request
    CodingAgentProvider (..),
    providerText,
    WorkspaceAccess (..),
    accessText,
    CodingAgentEffort (..),
    effortText,
    CodingAgentPrompt,
    mkCodingAgentPrompt,
    codingAgentPromptText,
    DeadlineMinutes,
    mkDeadlineMinutes,
    deadlineMinutesValue,
    VendorModelId,
    mkVendorModelId,
    vendorModelIdText,
    SkillDirectory,
    mkSkillDirectory,
    skillDirectoryPath,
    CodingAgentStep (..),

    -- * The outcome
    CodingAgentOutcome (..),
    CompletedRun (..),
    PartialRun (..),
    UncertainRun (..),
    UncertainReason (..),
    FailureReason (..),
    ResultCommit (..),
    ChangeSummary (..),
    ChangedFile (..),
    FileChange (..),
    EvidenceSummary (..),
    outcomeLabel,
    renderOutcome,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Dhall (FromDhall (..))
import Dhall qualified
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

data CodingAgentProvider = ClaudeCode | Codex
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

providerText :: CodingAgentProvider -> Text
providerText = \case
  ClaudeCode -> "claude"
  Codex -> "codex"

-- | Baikai's capability: Claude's permission mode, Codex's sandbox.
data WorkspaceAccess = ReadOnly | EditWorkspace | FullAccess
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

accessText :: WorkspaceAccess -> Text
accessText = \case
  ReadOnly -> "read-only"
  EditWorkspace -> "edit-workspace"
  FullAccess -> "full-access"

-- | No None or Minimal: Claude would silently raise them (ADR-40 forbids
-- substitution).
data CodingAgentEffort = EffortLow | EffortMedium | EffortHigh | EffortXHigh | EffortMax
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

effortText :: CodingAgentEffort -> Text
effortText = \case
  EffortLow -> "low"
  EffortMedium -> "medium"
  EffortHigh -> "high"
  EffortXHigh -> "xhigh"
  EffortMax -> "max"

-- | Nonblank, at most 256 KiB of UTF-8: the same as a declared tool's kept
-- output, since playbooks quote it (one keiro-upgrade edge's guidance is
-- 65 KB, FRIC-125). Baikai passes the prompt on standard input.
newtype CodingAgentPrompt = CodingAgentPrompt Text
  deriving stock (Eq, Show)

mkCodingAgentPrompt :: Text -> Either Text CodingAgentPrompt
mkCodingAgentPrompt value
  | Text.null (Text.strip value) = Left "a coding-agent prompt must not be blank"
  | ByteString.length (Text.Encoding.encodeUtf8 value) > 262144 = Left "a coding-agent prompt is at most 256 KiB"
  | otherwise = Right (CodingAgentPrompt value)

codingAgentPromptText :: CodingAgentPrompt -> Text
codingAgentPromptText (CodingAgentPrompt value) = value

-- | 1 to 720 minutes.
newtype DeadlineMinutes = DeadlineMinutes Natural
  deriving stock (Eq, Ord, Show)

mkDeadlineMinutes :: Natural -> Either Text DeadlineMinutes
mkDeadlineMinutes minutes
  | minutes < 1 || minutes > 720 = Left "a coding-agent deadline is 1 to 720 minutes"
  | otherwise = Right (DeadlineMinutes minutes)

deadlineMinutesValue :: DeadlineMinutes -> Natural
deadlineMinutesValue (DeadlineMinutes minutes) = minutes

-- | A vendor model id; absent means the vendor's default.
newtype VendorModelId = VendorModelId Text
  deriving stock (Eq, Show)

mkVendorModelId :: Text -> Either Text VendorModelId
mkVendorModelId value
  | Text.null (Text.strip value) || Text.any (\c -> c == ' ' || c == '\n') value = Left "a vendor model id must be nonblank and have no spaces"
  | Text.length value > 128 = Left "a vendor model id is at most 128 characters"
  | otherwise = Right (VendorModelId value)

vendorModelIdText :: VendorModelId -> Text
vendorModelIdText (VendorModelId value) = value

-- | A skill directory as declared. The runner resolves it, requires a
-- @SKILL.md@, and copies it into the attempt directory.
newtype SkillDirectory = SkillDirectory FilePath
  deriving stock (Eq, Show)

mkSkillDirectory :: Text -> Either Text SkillDirectory
mkSkillDirectory value
  | Text.null (Text.strip value) = Left "a skill directory must not be blank"
  | Text.length value > 1024 = Left "a skill directory path is at most 1024 characters"
  | otherwise = Right (SkillDirectory (Text.unpack value))

skillDirectoryPath :: SkillDirectory -> FilePath
skillDirectoryPath (SkillDirectory path) = path

-- | Decode with a base decoder, then apply the checked parser.
checked :: (b -> Either Text a) -> Dhall.Decoder b -> Dhall.Decoder a
checked parse Dhall.Decoder {extract = readBase, expected} =
  Dhall.Decoder
    { extract = \expression -> case Dhall.toMonadic (readBase expression) of
        Left problem -> Dhall.fromMonadic (Left problem)
        Right value -> either Dhall.extractError pure (parse value),
      expected
    }

instance FromDhall CodingAgentPrompt where autoWith _ = checked mkCodingAgentPrompt Dhall.strictText

instance FromDhall VendorModelId where autoWith _ = checked mkVendorModelId Dhall.strictText

instance FromDhall SkillDirectory where autoWith _ = checked mkSkillDirectory Dhall.strictText

instance FromDhall DeadlineMinutes where autoWith _ = checked mkDeadlineMinutes Dhall.natural

instance ToJSON CodingAgentPrompt where toJSON = toJSON . codingAgentPromptText

instance FromJSON CodingAgentPrompt where parseJSON = withText "CodingAgentPrompt" (either (fail . Text.unpack) pure . mkCodingAgentPrompt)

instance ToJSON VendorModelId where toJSON = toJSON . vendorModelIdText

instance FromJSON VendorModelId where parseJSON = withText "VendorModelId" (either (fail . Text.unpack) pure . mkVendorModelId)

instance ToJSON SkillDirectory where toJSON = toJSON . skillDirectoryPath

instance FromJSON SkillDirectory where parseJSON = withText "SkillDirectory" (either (fail . Text.unpack) pure . mkSkillDirectory)

instance ToJSON DeadlineMinutes where toJSON = toJSON . deadlineMinutesValue

instance FromJSON DeadlineMinutes where parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . mkDeadlineMinutes

-- | What a caller asks a coding agent to do. The declaration's
-- @CodingAgent@ arm and a flow body's capability call both supply one.
data CodingAgentStep = CodingAgentStep
  { provider :: !CodingAgentProvider,
    prompt :: !CodingAgentPrompt,
    access :: !WorkspaceAccess,
    model :: !(Maybe VendorModelId),
    effort :: !(Maybe CodingAgentEffort),
    deadlineMinutes :: !DeadlineMinutes,
    skills :: ![SkillDirectory]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data FileChange = Added | Modified | Deleted | Renamed
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ChangedFile = ChangedFile
  { path :: !Text,
    change :: !FileChange
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | At most 200 files listed; the rest are counted.
data ChangeSummary = ChangeSummary
  { files :: ![ChangedFile],
    omitted :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Never a 'Maybe': a completed run either left the base or committed.
data ResultCommit
  = Unchanged !Text
  | Committed !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data EvidenceSummary = EvidenceSummary
  { file :: !FilePath,
    digest :: !Text,
    strength :: !Text,
    session :: !(Maybe Text),
    reportedModel :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CompletedRun = CompletedRun
  { exit :: !Int,
    changes :: !ChangeSummary,
    result :: !ResultCommit,
    -- | The agent's last message, at most 16 KiB.
    finalMessage :: !Text,
    evidence :: !(Maybe EvidenceSummary)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data PartialRun = PartialRun
  { limit :: !DeadlineMinutes,
    uncommitted :: !ChangeSummary,
    evidence :: !(Maybe EvidenceSummary)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Why an attempt's fate cannot be established. It is never retried.
data UncertainReason
  = IntentWithoutLaunch
  | LauncherGoneWithoutResult
  | UnreadableResult
  | LauncherOverran
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data UncertainRun = UncertainRun
  { reason :: !UncertainReason,
    uncommitted :: !ChangeSummary,
    launcherPid :: !(Maybe Int)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data FailureReason
  = -- | Baikai exit 77.
    RefusedByCeiling !Text
  | -- | Exit 69, or the launcher itself is missing.
    Unstartable !Text
  | -- | Exit 64 or 78.
    Misconfigured !Text
  | DeadlineBeforeLaunch
  | -- | The tier does not admit coding agents (ADR-40's qualification gate).
    TierRefused !Text
  | WorkspaceUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CodingAgentOutcome
  = Completed !CompletedRun
  | Failed !FailureReason
  | TimedOut !PartialRun
  | Uncertain !UncertainRun
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

outcomeLabel :: CodingAgentOutcome -> Text
outcomeLabel = \case
  Completed {} -> "completed"
  Failed {} -> "failed"
  TimedOut {} -> "timed-out"
  Uncertain {} -> "uncertain"

renderOutcome :: CodingAgentOutcome -> Text
renderOutcome = \case
  Completed CompletedRun {exit, result, changes} ->
    "coding agent completed with exit " <> Text.pack (show exit) <> ", " <> commitText result <> ", " <> Text.pack (show (length changes.files)) <> " files changed"
  Failed reason -> "coding agent failed: " <> failureText reason
  TimedOut PartialRun {limit} -> "coding agent timed out after " <> Text.pack (show (deadlineMinutesValue limit)) <> " minutes; its changes are left uncommitted"
  Uncertain UncertainRun {reason} -> "coding agent outcome is uncertain (" <> Text.pack (show reason) <> "); inspect the worktree, it is never retried"
  where
    commitText = \case
      Unchanged base -> "no change from " <> Text.take 7 base
      Committed commit -> "commit " <> Text.take 7 commit
    failureText = \case
      RefusedByCeiling detail -> "refused by the operator's Baikai ceiling: " <> detail
      Unstartable detail -> "could not start: " <> detail
      Misconfigured detail -> "misconfigured: " <> detail
      DeadlineBeforeLaunch -> "the deadline passed before launch"
      TierRefused detail -> detail
      WorkspaceUnavailable detail -> "workspace unavailable: " <> detail
