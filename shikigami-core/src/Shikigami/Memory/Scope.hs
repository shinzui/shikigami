module Shikigami.Memory.Scope
  ( shikigamiNamespace,
    agentScope,
    sharedScope,
  )
where

import Data.Text (Text)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))

-- | The shikigami namespace used for every shikigami-owned memory/session.
shikigamiNamespace :: Namespace
shikigamiNamespace = Namespace "shikigami"

-- | Per-agent memory scope: everything THIS agent learned across its own runs.
-- Keyed by the agent's stable declared name (not a run id) so it is stable.
agentScope :: Text -> MemoryScope
agentScope agentName = ScopeEntity shikigamiNamespace (ScopeKind "agent") agentName

-- | Cross-agent shared learnings any shikigami agent may consult.
-- Currently unused; removal or declared semantics are deliberately deferred to
-- @docs\/plans\/34-memory-lifecycle-distillation-retention-and-shared-scope.md@.
sharedScope :: MemoryScope
sharedScope = ScopeGlobal shikigamiNamespace
