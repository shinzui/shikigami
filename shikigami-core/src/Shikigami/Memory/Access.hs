-- | How Shikigami names itself to Kioku's memory-space boundary.
--
-- Kioku 0.4 partitions everything it stores by 'MemorySpaceId' and records who acted as a
-- 'RecordedPrincipal'. Shikigami is a single-space deployment that predates both, so this module
-- exists to answer those two questions in exactly one place rather than at every call site.
--
-- Both answers are deliberately the conservative ones.
--
-- The space is 'legacyMemorySpaceId' — the space Kioku's migration @0011@ backfills existing rows
-- into. Every memory, session, and turn Shikigami has ever written lands there, so reads and
-- writes keep seeing the same data they saw before the partition existed. This is not a
-- placeholder for a missing decision: a single-space deployment has one space, and naming it the
-- one the backfill used is what keeps history reachable.
--
-- The actor is a 'LegacyPrincipal' carrying the agent's declared name. Shikigami has no principal
-- directory yet — resolving agents to real principals is what
-- @docs\/improvement-requests\/key-agent-continuity-by-meibo-principal.md@ (IR-9) asks for — and
-- Kioku's @KnownPrincipal@ means \"a directory issued this and vouched for it\". Minting one from
-- a free-text agent name would be inventing exactly the vouching nobody did, which Kioku's
-- ADR-\"historical attribution is marked, never invented\" exists to prevent. 'LegacyPrincipal' is
-- the honest label for an attribution that is real but unvouched, and it is what lets a later
-- reader tell the two apart.
--
-- When IR-9 lands, this module is the seam that changes: 'agentActor' starts returning
-- @KnownPrincipal@ against a Meibo-resolved 'Kioku.Api.Access.PrincipalRef', and the call sites
-- do not move.
module Shikigami.Memory.Access
  ( shikigamiMemorySpace,
    agentActor,
    shikigamiReadContext,
  )
where

import Kioku.Api.Access
  ( MemoryAccessContext,
    MemoryActor (MemoryActor),
    MemorySpaceId,
    PrincipalRef,
    RecordedPrincipal (LegacyPrincipal),
    assumeAuthorizedMemoryContext,
    legacyMemorySpaceId,
    legacyPrincipalRef,
    mkPrincipalRef,
  )
import Shikigami.Prelude

-- | The one memory space Shikigami reads and writes.
shikigamiMemorySpace :: MemorySpaceId
shikigamiMemorySpace = legacyMemorySpaceId

-- | The acting principal for a run, from the agent's declared name.
agentActor :: Text -> RecordedPrincipal
agentActor = LegacyPrincipal . legacyPrincipalRef

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

-- | The service's own principal. The name contains no @:@, so 'mkPrincipalRef' accepts it; the
-- @error@ is unreachable and would fire at module load rather than mid-run if that ever changed.
shikigamiServicePrincipal :: PrincipalRef
shikigamiServicePrincipal =
  case mkPrincipalRef "shikigami" of
    Right principal -> principal
    Left err -> error ("Shikigami.Memory.Access: invalid service principal: " <> show err)
