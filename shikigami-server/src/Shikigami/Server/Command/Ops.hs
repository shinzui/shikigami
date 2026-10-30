-- | The @keiro-ops@ operator console, mounted inside the @shikigami@ binary.
--
-- Keiro owns the durable-workflow engine, the transactional outbox, the
-- integration-event inbox, and the PGMQ job queues this service runs on. It also
-- ships the operator console for all of them — @keiro-ops@, a released package
-- whose command tree is explicitly embeddable ("Keiro.Ops.Embed"). This module
-- mounts that tree rather than reimplementing any of it.
--
-- == Why mount rather than reimplement
--
-- Keiro's own ADR-28
-- (@mori:\/\/shinzui\/keiro\/okf\/adrs\/concepts\/ADR-28@, "Operator commands wrap
-- supported library APIs and respect schema ownership") requires every operator
-- command to be a thin adapter over an exported operation of the library that
-- owns the affected state, and forbids reproducing a supported mutation with ad
-- hoc SQL or reading another library's private tables. A hand-written
-- @runs list@ over @keiro.keiro_workflows@ would violate that rule rather than
-- merely duplicate work — and it would then have to be kept in step with Keiro's
-- schema across every upgrade, which is the coupling
-- @docs\/dependency-cohort.md@'s "released versions only" rule exists to avoid.
--
-- What arrives with the mount is strictly broader than what this repository
-- would have written: journal decoding, awakeable inspection and cancellation,
-- lease release, workflow resurrection, outbox maintenance passes, and
-- stuck-timer triage were all out of scope and all come free.
--
-- == Application hooks
--
-- RunEvidence supplies its generated lifecycle replay-audit targets and the
-- same validated projection catalog used by live writes and queries. Its rich
-- payload targets are LiveOnly and PreserveAndReconcile: an audit checks the
-- lifecycle, and a destructive replay cannot reconstruct their payloads.
--
-- The embedded ResumeHook requires a registry over
-- @[Store, Error StoreError, IOE]@. Shikigami needs KirokuStoreResource and
-- Tracing as well; the worker-owned bounded action retains those effects.
-- Timer draining likewise stays with the owning worker dispatcher. Those two
-- embedded hooks remain absent; upstream timer triage stays available.
--
-- == How the database URL reaches the tree
--
-- The released public invocation record accepts the resolved connection string.
-- Its native --database-url flag contributes a named Settei source, so config
-- diagnostics and precedence see the same target the console uses. No process
-- environment adapter remains, and the library cannot fall back to a different
-- shell database once the value is supplied explicitly.
--
-- == What the audit line can and cannot say
--
-- Every invocation of the mounted tree emits two structured lines through
-- "Shikigami.Log", sharing one @invocation@ id: one before it runs and one
-- after, carrying the exit code. @keiro-ops@ knows nothing about
-- "Shikigami.Log", so this is the only place the lines can be written.
--
-- The correlating field is @invocation@ and deliberately not @run_id@.
-- "Shikigami.Log" documents @run_id@ as a run's idempotency key — equivalently
-- its keiro workflow id — and 'Shikigami.Log.Correlation.runCorrelationId' takes
-- exactly that. An operator invocation is not an agent run, so reusing the field
-- would break every @jq@ filter that treats @run_id@ as naming a run.
--
-- They name the command from the process's own argument vector, and they stop
-- there. The plan behind this module asked for outcome-named events —
-- @operator.workflow.cancelled@, @operator.dlq.redriven@ — and that is not
-- available from the runner: the only result @runOpsInvocation@ returns is an
-- 'ExitCode'. An exit code does not carry the outcome. @wf cancel --force@
-- against an already-terminal instance reports @already_completed@ and exits
-- /zero/, so a line reading @operator.workflow.cancelled@ inferred from a
-- successful exit would assert a cancellation that did not happen. Naming the
-- invocation and its exit code is what this layer can observe, so it is what
-- these lines claim.
--
-- @--database-url@'s value is redacted, because the argument vector is the one
-- place a connection string can arrive in the clear and a log line is the one
-- place it must not survive.
module Shikigami.Server.Command.Ops
  ( shikigamiOpsHooks,
    opsInvocationParser,
    runOps,
    opsConfigSources,
    -- | Exported for "Shikigami.Server.CommandSpec", which pins that no spelling
    -- of @--database-url@ survives into an audit line.
    redactDatabaseUrl,
  )
where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID.V4
import Keiro.Ops
  ( AppHooks (..),
    OpsInvocation (..),
    emptyAppHooks,
    opsCommandTree,
    runOpsInvocation,
  )
import Keiro.Ops.Embed (OpsAuditConfig (..))
import Keiro.Ops.Env (GlobalOptions (..))
import Keiro.Projection.Catalog.Operations (projectionCatalogOperations)
import Options.Applicative (Parser, infoParser)
import Settei.Optparse (cliOverride, cliSources)
import Settei.Source (Source)
import Shikigami.App.Config (AppConfig, databaseConnectionStringKey, revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Inspection.Aggregates (aggregateCatalog)
import Shikigami.Log qualified as Log
import Shikigami.RunEvidence.Catalog qualified as Evidence
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitWith)

-- | Mount only application hooks whose public effects match the runtime.
shikigamiOpsHooks :: AppHooks
shikigamiOpsHooks =
  emptyAppHooks
    { replayAudit = Just (OpsAuditConfig Evidence.auditTargets),
      projectionCatalog = Just (projectionCatalogOperations Evidence.validatedProjectionCatalog),
      aggregates = Just aggregateCatalog
    }

-- | The mounted tree's parser, lifted out of the 'ParserInfo' @keiro-ops@
-- builds so it can be an alternative inside Shikigami's own dispatcher.
--
-- This is a pure value: which commands mount depends only on which hooks are
-- present. The generated catalog and audit targets are pure, which lets the
-- tree be parsed before configuration is resolved, which
-- 'Shikigami.Server.Command.runAdmin' requires — configuration resolution
-- happens after parsing and before any action runs.
opsInvocationParser :: Parser OpsInvocation
opsInvocationParser = infoParser (opsCommandTree shikigamiOpsHooks)

-- | Run one parsed operator command against the configured database.
--
-- The exit code is @keiro-ops@'s own and is part of its contract: a mutating
-- command run without @--force@ prints its preview, names the exact
-- re-invocation on stderr, and exits @1@. Passing that through unchanged is the
-- point — a wrapper that swallowed it would turn "nothing happened, and here is
-- how to make it happen" into an apparent success.
runOps :: OpsInvocation -> AppConfig -> IO ()
runOps invocation config = do
  secret <- requireDatabaseUrl "ops" config
  let configured = invocation {globalOptions = invocation.globalOptions {databaseUrl = Just (revealSecretText secret)}}
  logger <- Log.newStderrLogger Log.Info
  command <- auditedCommand
  correlation <- UUID.toText <$> UUID.V4.nextRandom
  Log.logInfo
    logger
    "operator.ops.invoked"
    ["command" Aeson..= command, "invocation" Aeson..= correlation]
  exitCode <- runOpsInvocation shikigamiOpsHooks configured
  Log.logInfo
    logger
    "operator.ops.finished"
    [ "command" Aeson..= command,
      "invocation" Aeson..= correlation,
      "exit_code" Aeson..= exitStatus exitCode
    ]
  case exitCode of
    ExitSuccess -> pure ()
    failure -> exitWith failure

-- | Native flags remain real Settei sources, including redacted diagnostics.
-- The released public invocation record then carries the resolved value directly.
opsConfigSources :: OpsInvocation -> [Source]
opsConfigSources invocation =
  maybe [] (\value -> cliSources "--database-url" [cliOverride databaseConnectionStringKey value]) invocation.globalOptions.databaseUrl

-- | The invocation as the operator typed it, with any connection string removed.
--
-- Read from the process arguments to preserve the operator spelling.
-- This is exactly what was asked for, and it is the same
-- text @keiro-ops@ echoes back in its own preview messages.
auditedCommand :: IO Text
auditedCommand = redactDatabaseUrl . map Text.pack <$> getArgs

-- | Drop the value following @--database-url@, and the inline @--database-url=@
-- form, so a connection string cannot reach the log.
redactDatabaseUrl :: [Text] -> Text
redactDatabaseUrl = Text.unwords . go
  where
    go = \case
      [] -> []
      (argument : rest)
        | argument == "--database-url" ->
            argument : "<redacted>" : go (drop 1 rest)
        | "--database-url=" `Text.isPrefixOf` argument ->
            "--database-url=<redacted>" : go rest
        | otherwise -> argument : go rest

exitStatus :: ExitCode -> Int
exitStatus = \case
  ExitSuccess -> 0
  ExitFailure code -> code
