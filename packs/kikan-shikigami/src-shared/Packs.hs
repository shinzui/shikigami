-- | The flow packs the Kikan distribution composes: the Kikan binding and
-- the organizational packs. Every executable of the
-- distribution passes this one list to its role's entry point, so the worker
-- that runs a flow, the command that enqueues it and the admin command that
-- validates its manifest always agree on what exists.
module Packs (packs) where

import FlowPack.Examples (examplesPack)
import FlowPack.Initiative (initiativePack)
import FlowPack.PracticeReview (practiceReviewPack)
import FlowPack.Watchdog (watchdogPack)
import Kikan.Shikigami.Binding (kikanBinding)
import Shikigami.Flow.Sdk (FlowPack)

packs :: [FlowPack]
packs = [kikanBinding, examplesPack, practiceReviewPack, initiativePack, watchdogPack]
