-- | The Kikan binding: the one pack that knows Kikan's services
-- (docs/plans/135-move-the-kikan-service-bindings-out-of-shikigami-core-and-compose-a-kikan-distribution.md).
--
-- The kernel owns the ports (authority, outputs, approval channels, triggers,
-- tracker providers); this pack registers the Kikan adapter behind each one.
-- It is a plain value, like every pack: a registration that needs settings is
-- built from the validated 'PackSettings' when an executable starts, so the
-- role entry points keep taking @[FlowPack]@. The Kikan distribution
-- (@kikan-shikigami@) composes it; a stock executable never does, and refuses
-- a declaration or a setting that only this pack can honour.
module Kikan.Shikigami.Binding
  ( kikanBinding,
    kikanBindingName,
  )
where

import Kikan.Shikigami.Binding.Approval (kikanApprovalChannels)
import Kikan.Shikigami.Binding.Authority (authoritySettings, kikanAuthorityAdapter)
import Kikan.Shikigami.Binding.Output (kikanOutputRegistrations)
import Kikan.Shikigami.Binding.Settings (serviceSettings)
import Kikan.Shikigami.Binding.Tracker.Rei (reiTrackerProvider)
import Shikigami.Flow.Sdk

kikanBindingName :: FlowPackName
kikanBindingName = either (error . show) id (parseFlowPackName "kikan-binding")

-- | The binding's registrations arrive milestone by milestone; a flow pack
-- field is filled only when its adapter runs (ADR-1).
kikanBinding :: FlowPack
kikanBinding =
  FlowPack
    { name = kikanBindingName,
      flows = [],
      decisionPrograms = [],
      retainedCodecs = [],
      tasks = [],
      -- The Kikan-En authority's and the services' settings keep their
      -- kernel-era keys.
      settings = authoritySettings <> serviceSettings,
      triggers = noTriggerHooks,
      adminVerbs = [],
      gauges = [],
      authorities = [kikanAuthorityAdapter],
      outputs = kikanOutputRegistrations,
      approvalChannels = kikanApprovalChannels,
      trackerProviders = [reiTrackerProvider]
    }
