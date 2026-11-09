-- Hand-owned histories cover every declared lifecycle cell.
module Shikigami.MandateLifecycle.BehaviorHoles (behaviorWitnesses) where

import Shikigami.MandateLifecycle.Generated.BehaviorContract
import Shikigami.MandateLifecycle.Generated.Domain
import Shikigami.Prelude

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses = map witness behaviorRequirements
  where
    admitted = MandateAdmitted (MandateAdmittedData "mandate")
    stopped = MandateStopped (MandateStoppedData "mandate" 0 1)
    witness requirement =
      LiveWitness
        { key = requirement.key,
          history = case requirement.source of MandateLifecycleMissing -> []; MandateLifecycleActive -> [admitted]; MandateLifecycleStopped -> [admitted, stopped],
          command = case requirement.commandName of
            "AdmitMandate" -> AdmitMandate (AdmitMandateData "mandate")
            "AdvanceMandate" -> AdvanceMandate (AdvanceMandateData "mandate" 0 1)
            _ -> StopMandate (StopMandateData "mandate" 0 1),
          expected = case requirement.kind of
            RequiredRejection -> Rejects (if requirement.source == MandateLifecycleStopped then RejectNoOutgoingEdges else RejectNoMatchingEdge)
            LiveTransition ->
              Emits
                ( ( case requirement.commandName of
                      "AdmitMandate" -> admitted
                      "AdvanceMandate" -> MandateAdvanced (MandateAdvancedData "mandate" 0 1)
                      _ -> stopped
                  )
                    :| []
                )
            ReplayTransition -> error "no replay-only mandate transitions"
        }
