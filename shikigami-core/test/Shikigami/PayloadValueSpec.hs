module Shikigami.PayloadValueSpec (tests) where

import Data.Aeson (eitherDecode, encode, object, (.=))
import Data.Either (isLeft)
import Data.Foldable (for_)
import Data.Int (Int64)
import Data.Text qualified as Text
import Shikigami.Execution.Payload
import Shikigami.Execution.Transcript (PayloadRef (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "payload reference values"
    [ testCase "complete references retain exact string and numeric wire values" do
        let digest = "sha256:" <> Text.replicate 64 "a"
        locator <- right (parsePayloadId ("payload:" <> digest))
        hash <- right (parsePayloadDigest digest)
        size <- right (parsePayloadByteCount 42)
        let ref = PayloadRef locator hash size
        encode ref @?= encode (object ["payloadId" .= ("payload:" <> digest), "digest" .= digest, "bytes" .= (42 :: Integer)])
        eitherDecode (encode ref) @?= Right ref,
      testCase "payload locators retain exact bounded Unicode and reject C0 controls" do
        for_ ["ephemeral", "payload:fixture", " 名前 "] \value -> do
          locator <- right (parsePayloadId value)
          payloadIdText locator @?= value
          eitherDecode (encode locator) @?= Right locator
        for_ ["", "bad\nlocator", Text.replicate 257 "x"] \value ->
          assertBool "invalid locator" (isLeft (parsePayloadId value)),
      testCase "only canonical payload digest syntax enters the nominal field" do
        for_ ["", "sha256:a", "sha256:" <> Text.replicate 64 "A", "sha512:" <> Text.replicate 64 "a"] \value ->
          assertBool "invalid digest" (isLeft (parsePayloadDigest value))
        assertBool "invalid digest JSON" (isLeft (eitherDecode @PayloadDigest "\"invalid\"")),
      testCase "byte counts are positive signed-int64 units without the store's 1 MiB policy" do
        for_ [1, 1048577, toInteger (maxBound :: Int64)] \value -> do
          size <- right (parsePayloadByteCount value)
          payloadByteCount size @?= value
          encode size @?= encode value
          eitherDecode (encode size) @?= Right size
        for_ [0, -1, toInteger (maxBound :: Int64) + 1] \value ->
          assertBool "invalid byte count" (isLeft (parsePayloadByteCount value))
        for_ ["0", "-1", "1.5"] \bytes ->
          assertBool "invalid byte count JSON" (isLeft (eitherDecode @PayloadByteCount bytes))
    ]

right :: (Show error) => Either error value -> IO value
right = either (assertFailure . show) pure
