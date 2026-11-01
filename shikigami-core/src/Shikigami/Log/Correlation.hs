-- | The identifiers that let a human join one log line to one durable record.
--
-- Two questions come up whenever something goes wrong in this system. /Which
-- run was that?/ and /which call inside that run?/ This module defines the two
-- answers, and it defines them once so that everything which needs to name a
-- run or a call — log lines, spans, and the audit evidence a later plan
-- persists — uses the same string.
--
-- These live in their own module, separate from the logger in "Shikigami.Log",
-- on purpose. A consumer that needs to /store/ a correlation identifier should
-- not have to depend on a logging surface to name its type. "Shikigami.Log"
-- re-exports everything here, so a caller that only wants to log can import
-- that one module and never mention this one.
--
-- == Why these identifiers are stable across a crash
--
-- An agent run in this repository is a durable workflow: it is driven by keiro,
-- which journals each step to Postgres and can resume the run in a different
-- process after a crash. Anything derived from process-local state — a counter
-- in memory, a freshly generated UUID, a wall clock reading — would therefore
-- produce a /different/ identifier after a resume, and the log lines from
-- before the crash could no longer be joined to the ones after it.
--
-- Both identifiers here avoid that by being derived only from values the
-- journal already replays:
--
--   * A t'RunCorrelationId' is the run job's idempotency key, which is also the
--     keiro workflow id (see @runAgentRunWorkflow@ in
--     "Shikigami.Agent.Workflow" uses the job's validated natural key or a
--     deterministic UUIDv5 for keys containing journal separators. A resumed
--     run uses the same recorded workflow identity.
--
--   * A t'CallCorrelationId' is derived from the run id, the name of the
--     journaled step the call happens in, and the call's ordinal within that
--     step. A replay re-executes the same steps in the same order, so the same
--     call receives the same ordinal and therefore the same identifier.
--
-- == Why the rendered form is a contract, not an implementation detail
--
-- @docs\/plans\/51-run-evidence-aggregate-and-compliance-roll-up.md@ stores
-- these identifiers as durable audit evidence, and is explicitly forbidden from
-- minting a parallel scheme, because an operator disputing a compliance verdict
-- must be able to join the stored audit record to the log line for the same
-- call. Once that plan stores them, changing the rendering below is a database
-- migration rather than a refactor. 'renderCallCorrelationId' is pinned
-- byte-for-byte by @Shikigami.LogSpec@ for that reason.
module Shikigami.Log.Correlation
  ( -- * Identifying a run
    RunCorrelationId,
    runCorrelationId,
    renderRunCorrelationId,

    -- * Identifying a call within a run
    CallCorrelationId,
    callCorrelationId,
    parseCallCorrelationId,
    renderCallCorrelationId,

    -- * Field names
    runIdKey,
    callIdKey,
  )
where

import Data.Aeson.Key (Key)
import Data.Text qualified as Text
import Data.Text.Read qualified as TextRead
import Numeric.Natural (Natural)
import Shikigami.Prelude

-- | Which run. This is the run job's idempotency key, which is also the keiro
-- workflow id — see the module header for why that makes it survive a resume.
--
-- Construct it with 'runCorrelationId' rather than by coercion, so that every
-- call site is forced to name the value it is passing.
newtype RunCorrelationId = RunCorrelationId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

-- | Name a run by its idempotency key (equivalently, its keiro workflow id).
--
-- >>> renderRunCorrelationId (runCorrelationId "heartbeat:2026-08-05T12:00:00Z")
-- "heartbeat:2026-08-05T12:00:00Z"
runCorrelationId :: Text -> RunCorrelationId
runCorrelationId = RunCorrelationId

-- | The run identifier as it appears in a log line or an audit record.
renderRunCorrelationId :: RunCorrelationId -> Text
renderRunCorrelationId (RunCorrelationId t) = t

-- | Which call within a run. A \"call\" is one correlatable sub-operation of a
-- run — in practice a model call, but the type says nothing about the provider
-- and does not need to.
--
-- There is deliberately no constructor taking a raw t'Text'. A call identifier
-- that was not derived from a run, a step, and an ordinal would not be
-- reproducible after a resume, which is the one property this type exists to
-- guarantee.
newtype CallCorrelationId = CallCorrelationId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

parseCallCorrelationId :: Text -> Either Text CallCorrelationId
parseCallCorrelationId raw =
  let (prefix, ordinalText) = Text.breakOnEnd "/" raw
   in case TextRead.decimal ordinalText :: Either String (Natural, Text) of
        Right (ordinal, rest)
          | Text.null rest,
            ordinalText == Text.pack (show ordinal),
            "/" `Text.isInfixOf` Text.dropEnd 1 prefix ->
              Right (CallCorrelationId raw)
        _ -> Left "call correlation requires run/component/nonnegative-ordinal"

instance FromJSON CallCorrelationId where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseCallCorrelationId

-- | Derive the identifier of one call from the run it belongs to, the journaled
-- step it happens in, and its zero-based ordinal within that step.
--
-- The rendered form is @\<run id\>\/\<step\>\/\<ordinal\>@:
--
-- >>> renderCallCorrelationId (callCorrelationId (runCorrelationId "heartbeat:1") "run-behavior" 0)
-- "heartbeat:1/run-behavior/0"
--
-- A readable, joinable path was chosen over a hash so that an operator holding
-- a log line can read the run and the step straight off the identifier instead
-- of needing a lookup table. See the module header on why this rendering is a
-- contract.
callCorrelationId :: RunCorrelationId -> Text -> Natural -> CallCorrelationId
callCorrelationId (RunCorrelationId run) step ordinal =
  CallCorrelationId (run <> "/" <> step <> "/" <> Text.pack (show ordinal))

-- | The call identifier as it appears in a log line or an audit record.
renderCallCorrelationId :: CallCorrelationId -> Text
renderCallCorrelationId (CallCorrelationId t) = t

-- | The JSON key a run identifier is logged under. Named here so that a log
-- line and a stored audit record cannot drift onto different spellings.
runIdKey :: Key
runIdKey = "run_id"

-- | The JSON key a call identifier is logged under.
callIdKey :: Key
callIdKey = "call_id"
