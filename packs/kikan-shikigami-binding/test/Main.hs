module Main (main) where

import Kikan.Shikigami.Binding (kikanBinding)
import Kikan.Shikigami.Binding.ApprovalNotificationSpec qualified as ApprovalNotificationSpec
import Kikan.Shikigami.Binding.AuthoritySpec qualified as AuthoritySpec
import Kikan.Shikigami.Binding.IntakeSpec qualified as IntakeSpec
import Kikan.Shikigami.Binding.KanmonClientSpec qualified as KanmonClientSpec
import Kikan.Shikigami.Binding.OutputDispatchSpec qualified as OutputDispatchSpec
import Kikan.Shikigami.Binding.SinkHonestySpec qualified as SinkHonestySpec
import Kikan.Shikigami.Binding.WorkspaceActionProofSpec qualified as WorkspaceActionProofSpec
import Shikigami.Authority.Adapter (AuthorityAdapter (..))
import Shikigami.Flow.Builtin (builtinPack)
import Shikigami.Flow.Pack (FlowPack (..), composeFlowRegistry, flowPackNameText, registeredFlows)
import Shikigami.Objective.Tracker.Coordinate (coordinateText)
import Shikigami.Objective.Tracker.Provider (TrackerProviderRegistration (..))
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

main :: IO ()
main =
  defaultMain
    ( testGroup
        "kikan-shikigami-binding"
        [ testCase "the binding is named kikan-binding and composes beside the builtin pack" do
            flowPackNameText kikanBinding.name @?= "kikan-binding"
            case composeFlowRegistry [builtinPack, kikanBinding] of
              Left _ -> assertFailure "the binding refused to compose"
              Right registry -> length (registeredFlows registry) @?= either (const (-1)) (length . registeredFlows) (composeFlowRegistry [builtinPack])
            fmap (.mode) kikanBinding.authorities @?= ["kikan"]
            fmap (coordinateText . (.revision)) kikanBinding.trackerProviders @?= ["rei-v2-objectives/1"],
          AuthoritySpec.tests,
          WorkspaceActionProofSpec.tests,
          OutputDispatchSpec.tests,
          SinkHonestySpec.tests,
          KanmonClientSpec.tests,
          ApprovalNotificationSpec.tests,
          IntakeSpec.tests
        ]
    )
