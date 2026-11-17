-- | Declaration errors a manifest can carry that no runtime can fix.
--
-- The rest of this plan makes silently-ignored fields visible at dispatch: a
-- @ReiAction@ with nowhere to send fails into the retry path, and a
-- @recipientFrom@ that could not be answered logs that it fell back. Both are
-- recoverable — configure an endpoint, and the outbox drains; supply a default,
-- and the signal still reaches someone.
--
-- This module covers the case that is not recoverable. A @KizashiSignal@
-- declaring @recipientFrom = SubjectOwner@ or @AreaOwner@ with no
-- @defaultRecipient@ has asked to route by an ownership directory that does not
-- exist and named nobody to fall back to. There is no value the runtime could
-- choose that would be correct, and choosing one anyway is the behavior this
-- MasterPlan exists to remove. So it is refused up front, where the author is
-- looking at the manifest, rather than discovered later from a signal that went
-- to the deployment-wide fallback.
--
-- The check is a pure function over a loaded declaration so that the CLI, the
-- tests, and any future server-side validator all ask the same question.
module Shikigami.Sink.Validate
  ( sinkDeclarationErrors,
    validateKanmonRouteSegment,
  )
where

import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Prelude
import Shikigami.Sink.Outputs (outputConfigErrors, validateKanmonRouteSegment)

-- | Every declaration error in an agent's Kikan outputs, in declaration
-- order.
--
-- An empty list means they are deployable — not that every field will be
-- honored, which is what the dispatch-time warnings are for.
sinkDeclarationErrors :: AgentDecl -> [Text]
sinkDeclarationErrors AgentDecl {outputs} = concatMap outputConfigErrors outputs
