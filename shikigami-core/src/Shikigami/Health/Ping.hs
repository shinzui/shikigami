-- | The one definition of \"the database is reachable\".
--
-- Two packages answer @GET \/health\/ready@ — @shikigami-server@ for the HTTP
-- role and @shikigami-workers@ for the four worker roles — and neither may
-- depend on the other. Without a shared definition each would grow its own
-- notion of reachable, and the fleet would have two readiness contracts wearing
-- one name.
--
-- What lives here is deliberately only the probe, not the verdict. Turning a
-- 'Bool' into a @ProbeCheck@ needs @servant-health@, which pulls in
-- @servant-server@, and @shikigami-core@ is a domain library that must not link
-- HTTP route execution — @Shikigami.PackageArchitectureSpec@ fails the build if
-- it does. So core says whether PostgreSQL answered and each probe owner wraps
-- that in its own @boolCheck \"postgres\"@.
--
-- \"postgres\" is the name both wrappers must use: it is what appears in the 503
-- body, so it is an operator-facing string and not an implementation detail.
module Shikigami.Health.Ping
  ( databaseReachable,
    postgresCheckName,
  )
where

import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shikigami.Prelude

-- | The check name a failed PostgreSQL probe reports under.
--
-- Named once rather than spelled in each package, because the 503 body is a
-- wire contract an operator's runbook matches on.
postgresCheckName :: Text
postgresCheckName = "postgres"

-- | Can a pooled connection reach PostgreSQL and get an answer?
--
-- @select 1@ rather than a table read on purpose. Readiness asks whether this
-- process can talk to its database, and a query against an application table
-- would additionally fail on a missing migration or a revoked grant — real
-- problems, but ones a restart or a load-balancer eviction does not fix, which
-- is the test for whether something belongs in readiness at all.
--
-- Returns 'False' for any pool error rather than throwing: an unreachable
-- database is the expected outcome this exists to report, not an exception.
-- Callers still wrap it in @safeCheck@, because an exception thrown from
-- somewhere other than 'Pool.use' would otherwise become a 500 with a stack
-- trace instead of a probe report.
databaseReachable :: Pool -> IO Bool
databaseReachable pool =
  either (const False) (const True) <$> Pool.use pool (Session.statement () pingStatement)

pingStatement :: Statement () ()
pingStatement =
  preparable
    "select 1"
    Encoders.noParams
    (void (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8))))
