module Shikigami.Memory.Scope
  ( shikigamiNamespace,
    agentScope,
    legacyAgentScope,
    sharedScope,
  )
where

import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Shikigami.Agent.Principal (ResolvedAgentIdentity, principalScopeText)
import Shikigami.Prelude (Text)

-- | The shikigami namespace used for every shikigami-owned memory/session.
shikigamiNamespace :: Namespace
shikigamiNamespace = Namespace "shikigami"

-- | Per-agent memory scope: everything this durable identity learned across
-- its own runs. Verified work is keyed by Meibo principal; compatibility work
-- uses its visibly self-asserted identity.
agentScope :: ResolvedAgentIdentity -> MemoryScope
agentScope identity = ScopeEntity shikigamiNamespace (ScopeKind "agent") (principalScopeText identity)

-- | The scope spelling used before durable principals keyed agent state.
legacyAgentScope :: Text -> MemoryScope
legacyAgentScope agentName = ScopeEntity shikigamiNamespace (ScopeKind "agent") agentName

-- | Cross-agent shared learnings any shikigami agent may consult.
-- Currently unused; removal or declared semantics are deliberately deferred to
-- @docs\/plans\/34-memory-lifecycle-distillation-retention-and-shared-scope.md@.
sharedScope :: MemoryScope
sharedScope = ScopeGlobal shikigamiNamespace
