-- | What a local run needs from this machine before its first step, checked
-- before the run starts rather than discovered by the step that needs it
-- (FRIC-100, FRIC-101). @shikigami-local doctor@ prints these checks and
-- @shikigami-agent-run@ refuses to start a local run that fails one.
module Shikigami.Agent.Preflight
  ( -- * Checks
    Check (..),
    Problem (..),
    passed,
    renderCheck,

    -- * Local runs
    localRunChecks,
    grantCheck,
  )
where

import Baikai.Agent (AgentRunRequest, CeilingViolation (TimeoutExceeded), ceilingViolations, parseAgentCapability, parseAgentProvider, renderCeilingViolation)
import Baikai.Agent.Config (AgentConfigPaths (..), AgentJob (..), agentJob, agentJobRequest, defaultAgentConfigPaths, emptyAgentConfigPaths, loadAgentCeiling, renderAgentConfigError)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.Agent.Decl (AgentDecl (..), codingAgentAccessOf)
import Shikigami.Agent.Name (agentNameText)
import Shikigami.Capability.Declared (cliTools)
import Shikigami.CodingAgent.Types (CodingAgentProvider (..), WorkspaceAccess, accessText, providerText)
import Shikigami.Repository (repositoryIdText)
import Shikigami.Trust.LocalOperator.Approvals (LocalApprovals, RepositorySelector, renderApprovalsError, selectRepository)
import Shikigami.Trust.LocalOperator.Grant (GrantRefusal (..), GrantStore, renderGrantRefusal, resolveGrant)
import Shikigami.Trust.LocalOperator.Grant qualified as Grant
import Shikigami.Trust.LocalOperator.Host (codingAgentLauncher, gateExecutable)
import Shikigami.Workspace.Local.Checkout (processCheckoutResolver)
import System.Directory (doesFileExist, findExecutable, getPermissions)
import System.Directory qualified as Directory

-- | One prerequisite: a label, and what is wrong with it, if anything.
data Check = Check {label :: !Text, problem :: !(Maybe Problem)}
  deriving stock (Eq, Show)

-- | What failed, and the command or edit that fixes it.
data Problem = Problem {detail :: !Text, fix :: !Text}
  deriving stock (Eq, Show)

passed :: Check -> Bool
passed check = case check.problem of
  Nothing -> True
  Just _ -> False

-- | @ok    label@, or @FAIL  label: detail@ followed by its fix.
renderCheck :: Check -> Text
renderCheck Check {label, problem} = case problem of
  Nothing -> "ok    " <> label
  Just Problem {detail, fix} -> "FAIL  " <> label <> ": " <> detail <> "\n      fix: " <> fix

-- | The machine prerequisites of a local run of one declaration:
--
-- * the vendor CLI of a coding agent (@claude@ or @codex@) on @PATH@;
-- * @shikigami-agent-launch@, which mounts Baikai for each coding-agent step;
-- * @shikigami-local@, whose @gate@ runs declared tools and confines a coding
--   agent's shell calls;
-- * the operator's Baikai ceiling, which must admit the provider, its access
--   and, when the declaration has tools, the provider arguments that carry
--   them to the vendor CLI.
--
-- A declaration with no coding agent and no declared tools needs none of
-- these and gets no checks.
localRunChecks :: AgentDecl -> IO [Check]
localRunChecks decl = do
  let name = agentNameText decl.name
      tooled = not (null (cliTools decl.tools))
  coder <- case codingAgentAccessOf decl.behavior of
    Nothing -> pure []
    Just (provider, access) -> do
      let vendor = providerText provider
          vendorExecutable = case provider of ClaudeCode -> "claude"; Codex -> "codex"
      found <- findExecutable vendorExecutable
      launcher <- codingAgentLauncher
      launcherCheck <- helperCheck name "shikigami-agent-launch" "SHIKIGAMI_AGENT_LAUNCH" launcher
      ceiling' <- ceilingCheck name provider access (not (null decl.tools))
      pure
        [ Check (name <> ": " <> Text.pack vendorExecutable <> " on PATH") (if isJust found then Nothing else Just (Problem "not found" ("install " <> vendor <> " and log in"))),
          launcherCheck,
          ceiling'
        ]
  gate <-
    if tooled
      then (: []) <$> (gateExecutable >>= helperCheck name "shikigami-local" "SHIKIGAMI_LOCAL")
      else pure []
  pure (coder <> gate)

-- | A helper executable resolves to a file this process may run. The
-- resolver returns the bare name when it found nothing beside this
-- executable or on @PATH@.
helperCheck :: Text -> Text -> Text -> FilePath -> IO Check
helperCheck name helper variable path = do
  runnable <-
    if '/' `elem` path
      then do
        exists <- doesFileExist path
        if exists then Directory.executable <$> getPermissions path else pure False
      else isJust <$> findExecutable path
  pure
    ( Check
        (name <> ": " <> helper <> " resolves")
        ( if runnable
            then Nothing
            else
              Just
                ( Problem
                    ("not beside this executable, not on PATH and " <> variable <> " is unset")
                    ("put the directory of `cabal list-bin " <> helper <> "` on PATH, or set " <> variable <> " to its path")
                )
        )
    )

-- | The operator's Baikai ceiling admits a coding agent of this provider and
-- access, and admits provider arguments when the declaration has tools.
-- Only the operator's own file is read ('loadAgentCeiling'). A step's
-- timeout is its own deadline, checked when that step launches, so a
-- ceiling's @max-timeout@ is not judged here.
ceilingCheck :: Text -> CodingAgentProvider -> WorkspaceAccess -> Bool -> IO Check
ceilingCheck name provider access needsArguments = do
  paths <- defaultAgentConfigPaths
  loaded <- loadAgentCeiling emptyAgentConfigPaths {userConfig = paths.userConfig, repositoryRoot = paths.repositoryRoot}
  let label = name <> ": Baikai ceiling admits the coding agent"
      file = maybe "~/.config/baikai/agents.kdl (absent)" Text.pack paths.userConfig
  pure case (loaded, request) of
    (Left problem, _) -> Check label (Just (Problem (renderAgentConfigError problem) ("fix " <> file)))
    (_, Nothing) -> Check label (Just (Problem ("Baikai does not know provider " <> providerText provider <> " with access " <> accessText access) "upgrade baikai-agent"))
    (Right ceiling', Just admitted) -> case filter (not . isTimeout) (ceilingViolations ceiling' admitted) of
      [] -> Check label Nothing
      violations ->
        Check
          label
          ( Just
              ( Problem
                  (Text.intercalate "; " (renderCeilingViolation <$> violations))
                  ("widen the policy block of " <> file <> (if needsArguments then ", for example: policy { allow-provider-args #true }" else ""))
              )
          )
  where
    request :: Maybe AgentRunRequest
    request = do
      baikaiProvider <- parseAgentProvider (providerText provider)
      capability <- parseAgentCapability (accessText access)
      let job = agentJob baikaiProvider "." capability
          -- The runner's job (Shikigami.CodingAgent.Local) captures up to
          -- 32 MiB and carries the declared tools as provider arguments.
          shaped =
            job
              { providerArgs = ["--settings" | needsArguments],
                outputLimit = Just 33554432
              }
      pure (agentJobRequest shaped "preflight")
    isTimeout = \case
      TimeoutExceeded {} -> True
      _ -> False

-- | Whether the operator already granted this declaration on a repository,
-- through the approvals file or a stored terminal confirmation. Nothing is
-- asked or recorded.
grantCheck :: LocalApprovals -> GrantStore -> AgentDecl -> RepositorySelector -> IO Check
grantCheck approvals store decl selector = do
  let name = agentNameText decl.name
  selectRepository processCheckoutResolver approvals selector >>= \case
    Left problem -> pure (Check (name <> ": repository selectable") (Just (Problem (renderApprovalsError problem) "add the repository to ~/.config/shikigami/local-operator.dhall")))
    Right repository -> do
      let label = name <> ": granted on " <> repositoryIdText repository.identity
      resolveGrant Grant.Unattended approvals store (\_ -> pure (Right ())) decl repository >>= \case
        Right _ -> pure (Check label Nothing)
        Left (NoStoredGrant _) ->
          pure (Check label (Just (Problem "no stored grant" "run it once from a real terminal (not through a pipe such as tee) and confirm the grant")))
        Left refusal -> pure (Check label (Just (Problem (renderGrantRefusal refusal) "correct the approvals file entry, or revoke and confirm again")))
