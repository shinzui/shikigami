-- | The process-launch port of a trust tier.
--
-- The kernel never spawns a process itself ("Shikigami.PackageArchitectureSpec"
-- keeps @process@ out of core). A composition supplies a 'ProcessLauncher';
-- under the local-operator tier it is the host launcher in
-- @shikigami-core:local-host@. A request names an approved program and a
-- directory a worktree provider made, never model text.
module Shikigami.Workspace.Launch
  ( WorktreeRoot,
    worktreeRoot,
    worktreeRootPath,
    LaunchRequest (..),
    LaunchOutcome (..),
    LaunchResult (..),
    CapturedOutput (..),
    LaunchRefusal (..),
    renderLaunchRefusal,
    ProcessLauncher (..),
    unavailableLauncher,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Shikigami.Trust.LocalOperator.Approvals (LaunchDeadline, OutputLimit, ProgramPath)
import System.Exit (ExitCode)

-- | A directory a worktree provider opened for a run. Only that provider
-- builds one ('worktreeRoot' is for the provider and its tests).
newtype WorktreeRoot = WorktreeRoot FilePath
  deriving stock (Eq, Ord, Show)

worktreeRoot :: FilePath -> WorktreeRoot
worktreeRoot = WorktreeRoot

worktreeRootPath :: WorktreeRoot -> FilePath
worktreeRootPath (WorktreeRoot path) = path

data LaunchRequest = LaunchRequest
  { program :: !ProgramPath,
    arguments :: ![Text],
    directory :: !WorktreeRoot,
    -- | Environment names passed beyond the fixed minimal set.
    inherit :: ![Text],
    deadline :: !LaunchDeadline,
    outputLimit :: !OutputLimit
  }

data LaunchOutcome
  = Exited !ExitCode
  | -- | The deadline passed; the whole process group was terminated.
    DeadlineExpired
  deriving stock (Eq, Show)

-- | The first bytes of a stream, decoded leniently, and how many were
-- dropped beyond the bound.
data CapturedOutput = CapturedOutput
  { text :: !Text,
    dropped :: !Natural
  }
  deriving stock (Eq, Show)

data LaunchResult = LaunchResult
  { outcome :: !LaunchOutcome,
    stdout :: !CapturedOutput,
    stderr :: !CapturedOutput,
    elapsedMs :: !Natural
  }
  deriving stock (Eq, Show)

data LaunchRefusal
  = -- | This composition launches no process.
    LaunchUnavailable
  | LaunchFailed !Text
  deriving stock (Eq, Show)

renderLaunchRefusal :: LaunchRefusal -> Text
renderLaunchRefusal = \case
  LaunchUnavailable -> "this composition launches no process"
  LaunchFailed detail -> "the process could not be started: " <> Text.take 256 detail

newtype ProcessLauncher = ProcessLauncher
  { launch :: LaunchRequest -> IO (Either LaunchRefusal LaunchResult)
  }

unavailableLauncher :: ProcessLauncher
unavailableLauncher = ProcessLauncher {launch = \_ -> pure (Left LaunchUnavailable)}
