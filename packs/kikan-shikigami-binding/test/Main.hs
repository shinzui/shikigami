module Main (main) where

import Kikan.Shikigami.Binding (kikanBinding)
import Shikigami.Flow.Builtin (builtinPack)
import Shikigami.Flow.Pack (FlowPack (..), composeFlowRegistry, flowPackNameText, registeredFlows)
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
        ]
    )
