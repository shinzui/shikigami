-- | The stream trigger matcher (C3, class 2): does an @activity.v1@ Activity Envelope
-- match a declared agent's @StreamMatch@? The predicate is the AND of the present
-- (non-@Nothing@) predicates plus the multi-verb list, and — by default — the
-- *feedback guard* that excludes envelopes an agent produced (@actor.kind = "agent"@)
-- so agents do not react to their own output. The live consumer is added in M2.
module Shikigami.Trigger.Stream
  ( IncludeAgentActors (..),
    matchesStream,
    matchesStreamWith,
  )
where

import Shikigami.Activity (ActivityEnvelope (..), Actor (..), ActorKind (..), Subject (..))
import Shikigami.Agent.Decl (StreamMatch (..))

-- | Whether to include envelopes whose actor is itself an agent (opt-in; default off).
data IncludeAgentActors = ExcludeAgentActors | IncludeAgentActors
  deriving stock (Eq, Show)

-- | AND of present predicates; excludes @actor.kind = "agent"@ by default (the feedback guard).
matchesStream :: StreamMatch -> ActivityEnvelope -> Bool
matchesStream = matchesStreamWith ExcludeAgentActors

-- | As 'matchesStream', but the caller chooses whether agent-actor envelopes are included.
matchesStreamWith :: IncludeAgentActors -> StreamMatch -> ActivityEnvelope -> Bool
matchesStreamWith include m env =
  guardActor && verbOk && sourceOk && subjectOk
  where
    ActivityEnvelope {verb = eVerb, source = eSource, actor = eActor, subject = eSubject} = env
    Actor {kind = aKind} = eActor
    Subject {kind = eSubjectType} = eSubject
    StreamMatch {verb = mVerb, source = mSource, subjectType = mSubjectType, verbs = mVerbs} = m
    guardActor = case include of
      IncludeAgentActors -> True
      ExcludeAgentActors -> aKind /= AgentActor
    -- single-verb predicate AND multi-verb list (empty list = any verb)
    verbOk = maybe True (== eVerb) mVerb && (null mVerbs || eVerb `elem` mVerbs)
    sourceOk = maybe True (== eSource) mSource
    subjectOk = maybe True (== eSubjectType) mSubjectType
