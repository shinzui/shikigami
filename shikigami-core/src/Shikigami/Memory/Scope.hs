module Shikigami.Memory.Scope
  ( shikigamiNamespace,
    agentScope,
    sharedScope,
  )
where

import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Shikigami.Agent.Principal (ResolvedAgentIdentity, principalScopeText)

-- | The shikigami namespace used for every shikigami-owned memory/session.
shikigamiNamespace :: Namespace
shikigamiNamespace = Namespace "shikigami"

-- | Per-agent memory scope: everything THIS agent learned across its own runs.
-- Keyed by the agent's stable declared name (not a run id) so it is stable.
agentScope :: ResolvedAgentIdentity -> MemoryScope
agentScope identity = ScopeEntity shikigamiNamespace (ScopeKind "agent") (principalScopeText identity)

-- | Cross-agent shared learnings any shikigami agent may consult.
-- Currently unused; removal or declared semantics are deliberately deferred to
-- @docs\/plans\/34-memory-lifecycle-distillation-retention-and-shared-scope.md@.
sharedScope :: MemoryScope
sharedScope = ScopeGlobal shikigamiNamespace
