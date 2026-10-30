module Shikigami.Client.ConfigSpec (tests) where

import Control.Exception (evaluate)
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as Text
import Settei
import Settei.Env (envSnapshot, environmentSource)
import Settei.Optparse (DiagnosticMode (NoDiagnostic), SetteiOptions (..), cliOverride)
import Shikigami.Client.Config
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "client configuration"
    [ testCase "the production binding CAF is valid and unbound variables cannot redirect calls" do
        _ <- evaluate environmentBindings
        let result = resolveClientConfig options [] [] (environmentSource environmentBindings (envSnapshot [("UNBOUND_SERVER_URL", "https://wrong.example")]))
        case result.answer of
          Right config -> assertEqual "built-in server" "http://localhost:8080" config.server
          Left _ -> assertFailure "default client failed resolution",
      testCase "all source layers retain order and redact winning and shadowed credentials" do
        let file label url token = sourceFor label [(serverKey, RawText url), (tokenKey, RawText token)]
            files = [file "first-file" "https://first.example" "TOKEN_FILE_ONE", file "second-file" "https://second.example" "TOKEN_FILE_TWO"]
            environment = environmentSource environmentBindings (envSnapshot [("SHIKIGAMI_SERVER_URL", "https://environment.example"), ("SHIKIGAMI_API_TOKEN", "TOKEN_ENVIRONMENT")])
            named = [file "named-flags" "https://named.example" "TOKEN_NAMED"]
            selected = options {overrides = [cliOverride serverKey "https://override-one.example", cliOverride serverKey "https://final.example", cliOverride tokenKey "TOKEN_FINAL"]}
            result = resolveClientConfig selected named files environment
            rendered = renderResolutionText result.report <> renderResolutionJson result.report
        case result.answer of
          Right config -> assertEqual "last occurrence wins" "https://final.example" config.server
          Left _ -> assertFailure "layered resolution failed"
        mapM_ (\sentinel -> assertBool "secret candidate escaped diagnostic redaction" (not (sentinel `Text.isInfixOf` rendered))) ["TOKEN_FILE_ONE", "TOKEN_FILE_TWO", "TOKEN_ENVIRONMENT", "TOKEN_NAMED", "TOKEN_FINAL"]
        assertEqual "all lower candidates retain shadow origins without raw shadow values" 10 (Text.count "shadowed: " rendered)
        mapM_ (\label -> assertBool ("source occurrence was lost: " <> Text.unpack label) (label `Text.isInfixOf` rendered)) ["first-file", "second-file", "named-flags", "final.example"],
      testCase "a malformed winning URL fails rather than falling back to a valid file" do
        let environment = environmentSource environmentBindings (envSnapshot [("SHIKIGAMI_SERVER_URL", "not a URL")])
            result = resolveClientConfig options [] [sourceFor "valid-file" [(serverKey, RawText "https://valid.example")]] environment
        assertBool "bad winner must fail" (isLeft result.answer),
      testCase "credentials cannot hide inside a public server URL" do
        let selected = options {overrides = [cliOverride serverKey "https://secret:password@example.com"]}
            result = resolveClientConfig selected [] [] (environmentSource environmentBindings (envSnapshot []))
        assertBool "credential-bearing URL refused" (isLeft result.answer)
    ]

options :: SetteiOptions
options = SetteiOptions [] [] NoDiagnostic

sourceFor :: Text -> [(Key, RawValue)] -> Source
sourceFor label pairs = either (error . show) id (sourceFromPairs label BuiltInSource pairs)
