module Shikigami.Fixture.TypeSafe (TypeSafeFixture (..), withTypeSafeFixture, fixtureResponse, fixtureCatalog, fixturePrepared, fixtureRuntime, fixtureTicket, mustRight) where

import Baikai.Model qualified as Model
import Baikai.Provider.Registry (newProviderRegistryFrom)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, tryPutMVar)
import Control.Monad (void)
import Data.Aeson (Value, eitherDecode, encode, object, toJSON, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Handan.Runtime (Runtime (..))
import Keiro.Workflow.Types (WorkflowId (..))
import Network.HTTP.Types (mkStatus)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import Settei.Env (envSnapshot, environmentSource)
import Settei.Key (parseKey)
import Settei.Optparse (DiagnosticMode (NoDiagnostic), cliOverride)
import Shikigami.App.Config (AppConfig (..), Role (RunBehaviorRole), environmentBindings)
import Shikigami.App.Config.Load (ConfigOptions (..), ConfigRun (..), appConfigRun)
import Shikigami.Attestation.PolicyValue (mkCeiling)
import Shikigami.Decision.Contract
import Shikigami.Decision.ModelCatalog
import Shikigami.Log.Correlation (runCorrelationId)
import Shikigami.Program.Decision
import Shikigami.Program.Decision.JudgmentExample
import Shikigami.Program.DecisionRunner
import Shikumi.LLM (defaultLLMConfig)

-- Only public synthetic data is retained by this local server.
data TypeSafeFixture = TypeSafeFixture
  {endpoint :: !Text, requests :: !(IO [(Text, Value)]), ready :: !(MVar ())}

withTypeSafeFixture :: Int -> Int -> Value -> (TypeSafeFixture -> IO a) -> IO a
withTypeSafeFixture status delay reply use = do
  captured <- newIORef []
  ready <- newEmptyMVar
  let application request respond = do
        bytes <- Wai.strictRequestBody request
        let value = mustRight (eitherDecode bytes)
        atomicModifyIORef' captured (\xs -> (xs <> [(TE.decodeUtf8 (Wai.rawPathInfo request), value)], ()))
        void (tryPutMVar ready ())
        threadDelay delay
        respond (Wai.responseLBS (mkStatus status "fixture") [("Content-Type", "application/json"), ("x-typesafe-request-id", "public-fixture-request")] (encode reply))
  testWithApplication (pure application) \port ->
    use (TypeSafeFixture ("http://127.0.0.1:" <> Text.pack (show port)) (readIORef captured) ready)

fixtureResponse :: Value
fixtureResponse =
  object
    [ "model" .= ("jev-fixture-version" :: Text),
      "usage" .= object ["input_tokens" .= (120 :: Int), "output_tokens" .= (3 :: Int)],
      "answers"
        .= object
          [ "urgent" .= object ["type" .= ("noul" :: Text), "noul" .= (0.83 :: Double)],
            "category" .= object ["type" .= ("choice" :: Text), "choice" .= ("technical" :: Text), "probabilities" .= object ["billing" .= (0.2 :: Double), "technical" .= (0.7 :: Double)], "confidence" .= (0.65 :: Double)],
            "severity" .= object ["type" .= ("score" :: Text), "score" .= (1.5 :: Double), "probabilities" .= object ["0" .= (0.1 :: Double), "1" .= (0.3 :: Double), "2" .= (0.6 :: Double)], "confidence" .= (0.55 :: Double), "legend" .= object ["0" .= ("Minor" :: Text), "1" .= ("Disruptive" :: Text), "2" .= ("Blocking" :: Text)]]
          ]
    ]

fixtureTicket :: Ticket
fixtureTicket = Ticket "Checkout is unavailable."

fixtureCatalog :: Text -> ModelCatalog
fixtureCatalog endpoint =
  let entries = [object ["alias" .= ("judge" :: Text), "version" .= ("1" :: Text), "bindingId" .= ("typesafe-fixture" :: Text), "bindingVersion" .= ("1" :: Text), "provider" .= ("typesafe" :: Text), "model" .= ("jev-latest" :: Text), "thinking" .= ("default" :: Text), "base_url" .= endpoint, "timeout_ms" .= (30000 :: Int)]]
      values = [("behavior.decisionModels", TE.decodeUtf8 (LBS.toStrict (encode entries))), ("credentials.providers.typesafe.api_key", "public-fixture-key")]
      result = appConfigRun RunBehaviorRole ConfigOptions {configPaths = [], namedSources = [], overrides = [cliOverride (mustRight (parseKey key)) value | (key, value) <- values], diagnosticMode = NoDiagnostic} (Right []) (environmentSource environmentBindings (envSnapshot []))
   in case result.resolved of
        Just config -> mustRight config.decisionModelCatalog
        Nothing -> error (Text.unpack result.standardError)

fixturePrepared :: ModelCatalog -> PreparedDecision
fixturePrepared catalog = case catalogDescriptors catalog of
  [descriptor] -> PreparedDecision (decisionPreparationId (toJSON fixtureTicket)) (runCorrelationId "typesafe-fixture") (WorkflowId "typesafe-fixture") initialDecisionGeneration judgmentDecisionSlot (Shikigami.Program.Decision.descriptor (programRef judgmentProgram)) (toJSON fixtureTicket) descriptor Nothing
  _ -> error "one fixture model required"

fixtureRuntime :: ModelCatalog -> DecisionCallHooks -> IO DecisionRuntime
fixtureRuntime catalog hooks = do
  registry <- newProviderRegistryFrom []
  let prepared = fixturePrepared catalog
      binding = mustRight (pinnedBinding catalog prepared.model)
  pure
    DecisionRuntime
      { runtime = Runtime (defaultLLMConfig registry) (bindingModel binding),
        programs = mustRight (programRegistry [SomeProgram judgmentProgram]),
        catalog,
        profile = Nothing,
        hooks,
        providers = decisionProviders,
        timeoutMicros = mustRight (parseDecisionTimeout 2000000),
        callLimit = mustRight (mkCeiling 4)
      }

mustRight :: (Show e) => Either e a -> a
mustRight = either (error . show) id
