-- | How Shikigami names itself to Kioku's memory-space boundary.
--
-- Kioku 0.4 partitions everything it stores by 'MemorySpaceId' and records who acted as a
-- 'RecordedPrincipal'. Shikigami is a single-space deployment that predates both, so this module
-- exists to answer those two questions in exactly one place rather than at every call site.
--
-- The space is 'legacyMemorySpaceId' — the space Kioku's migration @0011@ backfills existing rows
-- into. Every memory, session, and turn Shikigami has ever written lands there, so reads and
-- writes keep seeing the same data they saw before the partition existed. This is not a
-- placeholder for a missing decision: a single-space deployment has one space, and naming it the
-- one the backfill used is what keeps history reachable.
--
-- The actor is a @KnownPrincipal@ over a ref this service mints from the agent's declared name.
--
-- That is the second answer this module has given, and the first one was wrong. It originally
-- recorded 'Kioku.Api.Access.LegacyPrincipal', reasoning that @KnownPrincipal@ claims a directory
-- vouched for the principal and Shikigami has no directory. Kioku settled the question in ADR-5
-- (@historical-attribution-is-marked-never-invented@, revised 2026-08-18) and the premise was
-- wrong twice over. @KnownPrincipal@ asserts that a principal was /vouched for/, not that a
-- /directory/ did the vouching: with a directory, @authorizeMemoryAccess@ resolves it; without
-- one, 'assumeAuthorizedMemoryContext' makes the host itself accountable for the ref it supplies.
-- And @LegacyPrincipal@ is decode-side only — it means \"a pre-memory-space event\", so stamping
-- it on something written today asserts the event predates memory spaces, which is false.
--
-- So the honest label for an unvouched-but-real attribution is not a weaker constructor; it is a
-- ref that says what it is. The kind prefix is where ADR-5 puts self-assertion, because
-- 'Kioku.Api.Access.PrincipalRef' names /what a principal is/ while @RecordedPrincipal@ names
-- /how much history knows/. Hence @shikigami.agent.\<name\>@: legible, stable, and obviously not
-- directory-issued to anyone reading the stream.
--
-- The corrected writes are not backfilled. Rows written before this change carry
-- @kioku:legacy:\<name\>@ and are wrong in the way described above; Shikigami has no users and no
-- data worth preserving, so the fix is to recreate rather than migrate. This is exactly the
-- asymmetry that made changing it now rather than at IR-9 the cheap option: an append-only event
-- store makes a false attribution permanent the moment real traffic exists.
--
-- When IR-9 (@docs\/improvement-requests\/key-agent-continuity-by-meibo-principal.md@) lands and
-- Meibo can resolve agents, 'agentActor' takes its ref from Meibo instead of minting one, and the
-- call sites still do not move. The write path can move to Kioku's @*WithContext@ surface at the
-- same time, which is what retires the deprecation warnings this module's callers carry.
module Shikigami.Memory.Access
  ( shikigamiMemorySpace,
    agentActor,
    shikigamiReadContext,
    shikigamiWriteContext,
  )
where

import Kioku.Api.Access
  ( MemoryAccessContext,
    MemoryActor (MemoryActor),
    MemorySpaceId,
    RecordedPrincipal (KnownPrincipal),
    assumeAuthorizedMemoryContext,
    legacyMemorySpaceId,
  )
import Kioku.Api.Access qualified as Access
import Shikigami.Agent.Principal (ResolvedAgentIdentity, principalRefFor)
import Shikigami.Prelude

-- | The one memory space Shikigami reads and writes.
shikigamiMemorySpace :: MemorySpaceId
shikigamiMemorySpace = legacyMemorySpaceId

-- | The acting principal for a run, from the agent's declared name.
agentActor :: ResolvedAgentIdentity -> RecordedPrincipal
agentActor = KnownPrincipal . principalRefFor

-- | The authorization context Shikigami reads memory under.
--
-- Reads need a 'MemoryAccessContext', and minting one needs a real
-- 'Kioku.Api.Access.PrincipalRef' — there is no legacy-shaped actor for a context the way there
-- is for a recorded fact. That is sound here for a reason worth stating: a context is a decision,
-- not a document. Kioku gives it no 'FromJSON' instance precisely so it cannot be written down and
-- replayed, and no read path persists its actor. So naming the /service/ here records nothing and
-- invents nothing; it is the honest actor for a read the process itself is making, and it is why
-- the write path still goes through 'agentActor' rather than reusing this.
--
-- 'assumeAuthorizedMemoryContext' is the trusted in-process entry point: Shikigami resolves and
-- authorizes an agent long before memory is touched, which is exactly the case Kioku documents it
-- for. When IR-9 lands and there is a directory to ask, this becomes an 'authorizeMemoryAccess'
-- call and the call sites again do not move.
shikigamiReadContext :: MemoryAccessContext
shikigamiReadContext =
  assumeAuthorizedMemoryContext shikigamiMemorySpace (MemoryActor shikigamiServicePrincipal)

-- | The authorization context Shikigami writes an agent's memory under.
--
-- Distinct from 'shikigamiReadContext' in exactly one way, and the difference is the whole point:
-- its actor is the /agent/, not the service. Kioku's @underContext@ refuses a write whose
-- @actorPrincipal@ disagrees with the context's recorded actor, so a write that records
-- @agentActor name@ must be authorized by a context built from the same ref. Building both from
-- 'agentPrincipal' makes that agreement structural rather than a thing two call sites remember.
--
-- Use this with kioku's @*WithContext@ surface. The unsuffixed wrappers ('Kioku.Session.start'
-- and friends) are deprecated and confined to the legacy space; they still appear in this
-- repository, and retiring them is
-- @docs\/plans\/54-key-durable-agent-state-by-meibo-principal.md@'s work — but no new call site
-- should join them.
shikigamiWriteContext :: ResolvedAgentIdentity -> MemoryAccessContext
shikigamiWriteContext identity =
  assumeAuthorizedMemoryContext shikigamiMemorySpace (MemoryActor (principalRefFor identity))

-- | The service's own principal. The name contains no @:@, so 'mkPrincipalRef' accepts it; the
-- @error@ is unreachable and would fire at module load rather than mid-run if that ever changed.
shikigamiServicePrincipal :: Access.PrincipalRef
shikigamiServicePrincipal =
  case Access.mkPrincipalRef "shikigami" of
    Right principal -> principal
    Left err -> error ("Shikigami.Memory.Access: invalid service principal: " <> show err)
