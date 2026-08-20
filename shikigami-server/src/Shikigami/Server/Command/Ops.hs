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
-- == Why every hook is empty
--
-- 'AppHooks' has four fields, and each one gates commands that need a value only
-- the embedding application can supply. All four are 'Nothing' here, for three
-- different reasons.
--
-- @replayAudit@ and @projectionCatalog@ are empty because Shikigami has neither.
-- @docs\/architecture\/shikigami-domain-inventory.md@ established that this
-- service has no aggregate, read model, projection, router, or process manager
-- of its own. Populating either would advertise a capability the runtime does
-- not have, which is the mistake
-- @docs\/adr\/0001-declare-only-what-the-runtime-executes.md@ exists to prevent.
--
-- @workflowResume@ is empty because the types do not line up and the verb is not
-- worth the change that would make them. @Keiro.Ops.Workflow.ResumeHook@ wants a
-- @WorkflowRegistry '[Store, Error StoreError, IOE]@; Shikigami's registry is
-- over @Kioku.App.AppEffects@, which is @'[Store, KirokuStoreResource, Error
-- StoreError, Tracing, IOE]@ — a wider row. Narrowing it is a change to how this
-- service builds its registry, and it would buy @wf resume-once@, a single
-- bounded pass that the worker process's resume loop already performs
-- continuously.
--
-- @timerFire@ is empty for the same reason, which is worth stating because the
-- plan that led here expected to populate it. The hook gates exactly one
-- command, @timer drain-once@; the entire timer /triage/ surface —
-- @timer stuck list@, @timer requeue@, @timer cancel@, @timer dead-letter@ —
-- mounts unconditionally
-- (@keiro-ops\/src\/Keiro\/Ops\/Timer.hs:57-96@). So the hook is a convenience
-- over a loop the worker already runs, not a capability, and skipping it also
-- sidesteps a package-boundary problem: @shikigamiTimerFallback@ lives in
-- @shikigami-workers@, which @shikigami-server@ may not import.
--
-- The tree drops an unhooked command from the parser entirely rather than
-- mounting it and failing at run time, so none of these absences shows up as a
-- verb that exists and then refuses.
--
-- == How the database URL reaches the tree
--
-- "Keiro.Ops" exports @OpsInvocation@ without its constructor, so the parsed
-- value is opaque and its @globalOptions.databaseUrl@ cannot be written. What
-- @runOpsInvocation@ does instead is resolve the connection string itself,
-- preferring @--database-url@, then @KEIRO_OPS_DATABASE_URL@, then
-- @DATABASE_URL@ (@keiro-ops\/src\/Keiro\/Ops\/Env.hs:56-61@).
--
-- So 'runOps' sets @KEIRO_OPS_DATABASE_URL@ in its own process, from the
-- Settei-resolved 'AppConfig', immediately before the call. That preserves the
-- intended precedence — an explicit @--database-url@ still wins — and it does
-- not weaken this repository's rule that configuration comes from Settei:
-- Settei still decides the value, and the environment is only the wire it
-- travels down into a library that offers no other entry point.
--
-- Setting it is not conditional on the operator having supplied one.
-- 'requireDatabaseUrl' fails with the same message and exit code as any other
-- missing required key, which is better than falling through to a
-- @DATABASE_URL@ that happens to be in the operator's shell and silently aiming
-- the console at a database @shikigami --explain-config@ does not name.
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
-- honestly available: @OpsInvocation@ is abstract, so the verb cannot be read
-- from the parsed value, and the only result @runOpsInvocation@ returns is an
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
  ( AppHooks,
    OpsInvocation,
    emptyAppHooks,
    opsCommandTree,
    runOpsInvocation,
  )
import Options.Applicative (Parser, infoParser)
import Shikigami.App.Config (AppConfig, revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Log qualified as Log
import System.Environment (getArgs, setEnv)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitWith)

-- | Shikigami mounts the whole tree with no application hooks. See the module
-- header for why each of the four is empty.
shikigamiOpsHooks :: AppHooks
shikigamiOpsHooks = emptyAppHooks

-- | The mounted tree's parser, lifted out of the 'ParserInfo' @keiro-ops@
-- builds so it can be an alternative inside Shikigami's own dispatcher.
--
-- This is a pure value: which commands mount depends only on which hooks are
-- present, and all of Shikigami's are statically absent. That is what lets the
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
  setEnv "KEIRO_OPS_DATABASE_URL" (Text.unpack (revealSecretText secret))
  logger <- Log.newStderrLogger Log.Info
  command <- auditedCommand
  correlation <- UUID.toText <$> UUID.V4.nextRandom
  Log.logInfo
    logger
    "operator.ops.invoked"
    ["command" Aeson..= command, "invocation" Aeson..= correlation]
  exitCode <- runOpsInvocation shikigamiOpsHooks invocation
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

-- | The invocation as the operator typed it, with any connection string removed.
--
-- Read from the process arguments because the parsed 'OpsInvocation' is opaque.
-- That is a fair source: it is exactly what was asked for, and it is the same
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
