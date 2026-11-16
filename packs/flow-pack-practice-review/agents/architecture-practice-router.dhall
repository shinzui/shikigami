--| architecture-practice-router: route a version-1 review trigger to an
-- authorized specialist. Producers send the raw trigger here and name no
-- specialist (docs/user/architecture-practice-reviews.md).
--
-- The flow lives in this pack. Run it from a worker composed with the pack
-- (kikan-shikigami-worker); the stock worker refuses the manifest.
let A = ../../../schema/Agent.dhall

in  A.Agent::{
    , name = "architecture-practice-router"
    , description =
        "Routes architecture-practice payloads to declared specialists"
    , behavior = A.Behavior.Flow { name = "architecture-practice-router" }
    , trigger = A.Trigger.Event { eventType = "proof.architecture-practice" }
    , delegates = [ "opentelemetry-practice-reviewer", "code-researcher" ]
    , delegationBudget = Some 4
    , routing = Some
      { maxSelections = 2
      , minimumConfidence = A.RouterConfidence.RoutingMedium
      , onNoMatch = A.NoMatchPolicy.ReturnNoMatch
      , onAmbiguous = A.AmbiguousPolicy.ReturnAmbiguous
      }
    }
