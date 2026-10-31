module Shikigami.AgentValueSpec (tests) where

import Control.Exception (SomeException, try)
import Data.Aeson (eitherDecode, encode)
import Data.Either (isLeft)
import Data.Foldable (for_)
import Data.Text (Text)
import Dhall qualified
import Kioku.Api.Access (principalRefText)
import Shikigami.Agent.Delegate.Depth (DelegationDepth, initialDepth, nextDepth, parseDelegationDepth)
import Shikigami.Agent.ExpertiseKey (ExpertiseKey, duplicateExpertiseKeys, expertiseKeyText, parseExpertiseKey)
import Shikigami.Agent.Name (AgentName, agentNameText, mkAgentName)
import Shikigami.Agent.Principal
import Shikigami.Router.SelectionLimit (SelectionLimit, parseSelectionLimit, selectionLimitNatural)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "agent values"
    [ testCase "names retain exact nonempty bytes through JSON and Dhall" do
        for_ ["a:b", "a.b", " 名 前 ", " "] \raw -> do
          name <- right (mkAgentName raw)
          agentNameText name @?= raw
          encode name @?= encode raw
          eitherDecode (encode name) @?= Right name
        decoded <- Dhall.input Dhall.auto "\"a:b\""
        mkAgentName "a:b" @?= Right decoded,
      testCase "empty names refuse at each input boundary" do
        assertBool "factory" (isLeft (mkAgentName ""))
        assertBool "JSON" (isLeft (eitherDecode @AgentName "\"\""))
        bad <- try @SomeException (Dhall.input @AgentName Dhall.auto "\"\"")
        assertBool "Dhall" (isLeft bad),
      testCase "expertise keys retain spelling while duplicates use normalized comparison" do
        key <- right (parseExpertiseKey " OpenTelemetry ")
        expertiseKeyText key @?= " OpenTelemetry "
        encode key @?= encode (" OpenTelemetry " :: Text)
        eitherDecode (encode key) @?= Right key
        folded <- right (parseExpertiseKey "opentelemetry")
        duplicateExpertiseKeys [key, folded, key] @?= [folded]
        assertBool "blank factory" (isLeft (parseExpertiseKey " \t"))
        assertBool "blank JSON" (isLeft (eitherDecode @ExpertiseKey "\" \""))
        bad <- try @SomeException (Dhall.input @ExpertiseKey Dhall.auto "\" \"")
        assertBool "blank Dhall" (isLeft bad),
      testCase "selection ceilings retain numeric wire values and reject invalid admission" do
        for_ [1, 16] \raw -> do
          limit <- right (parseSelectionLimit raw)
          selectionLimitNatural limit @?= raw
          encode limit @?= encode raw
          eitherDecode (encode limit) @?= Right limit
        for_ ["0", "17", "-1", "1.5"] \bytes ->
          assertBool "invalid JSON ceiling" (isLeft (eitherDecode @SelectionLimit bytes))
        for_ ["0", "17"] \source -> do
          bad <- try @SomeException (Dhall.input @SelectionLimit Dhall.auto source)
          assertBool "invalid Dhall ceiling" (isLeft bad),
      testCase "depth has checked arithmetic independent of the child policy" do
        zero <- right (parseDelegationDepth 0)
        zero @?= initialDepth
        encode zero @?= "0"
        eitherDecode (encode zero) @?= Right zero
        one <- right (parseDelegationDepth 1)
        nextDepth zero @?= Just one
        largest <- right (parseDelegationDepth (toInteger (maxBound :: Int)))
        nextDepth largest @?= Nothing
        assertBool "negative depth" (isLeft (parseDelegationDepth (-1)))
        assertBool "overflow depth" (isLeft (parseDelegationDepth (toInteger (maxBound :: Int) + 1)))
        assertBool "fractional JSON" (isLeft (eitherDecode @DelegationDepth "0.5")),
      testCase "compatibility scopes separate punctuation and accept every admitted name" do
        colon <- resolved "a:b"
        dot <- resolved "a.b"
        principalScopeText colon @?= "shikigami.agent.v2.641ea5cf-9fd6-519f-ac21-7f05af376cac"
        principalScopeText dot @?= "shikigami.agent.v2.1e755af6-d41e-5a50-9287-2df6ddf0d822"
        assertBool "distinct scopes" (principalScopeText colon /= principalScopeText dot)
        for_ ["a:b", "a.b", "a#b", "a%b", "a/b", " 名 前 ", " "] \raw -> do
          identity <- resolved raw
          principalRefText (principalRefFor identity) @?= principalScopeText identity
          again <- resolved raw
          again @?= identity
          let wire = resolvedIdentity identity
          eitherDecode (encode wire) @?= Right wire
        assertBool "empty compatibility name" (isLeft (eitherDecode @AgentIdentity "{\"kind\":\"compatibility\",\"agentName\":\"\"}"))
    ]

right :: (Show problem) => Either problem value -> IO value
right = either (assertFailure . show) pure

resolved :: Text -> IO ResolvedAgentIdentity
resolved raw = right (mkAgentName raw >>= resolveAgentIdentity . compatibilityIdentity)
