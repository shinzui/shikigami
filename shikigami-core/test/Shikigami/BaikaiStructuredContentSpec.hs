module Shikigami.BaikaiStructuredContentSpec (tests) where

import Baikai.Api (Api (Custom))
import Baikai.Content (AssistantContent (..), DataContent (..), TextContent (..), UserContent (..))
import Baikai.Context qualified as Context
import Baikai.Evidence qualified as Evidence
import Baikai.Message qualified as Message
import Baikai.Model (emptyModel)
import Baikai.Options (emptyOptions)
import Baikai.Provider (apiProviderWith)
import Baikai.Provider.Registry (newProviderRegistryFrom)
import Baikai.Response (Response (..), emptyResponse)
import Baikai.Response.JSON (responseFromJSON, responseToJSON)
import Baikai.Stream (liftCompleteToStream)
import Baikai.Trace (TraceEvent (..), TraceSink (..))
import Control.Lens ((&), (.~))
import Data.Aeson (eitherDecode, encode, object, (.=))
import Data.Aeson.Types (parseEither)
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, liftIO, runEff, type (:>))
import Effectful.Concurrent (runConcurrent)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import Shikigami.Behavior.Run (completeBehaviorRequest, newBehaviorEnv)
import Shikigami.Decision.Answer
import Shikigami.Execution.Policy (defaultHarnessPolicy, validateTerminalOutput)
import Shikigami.Execution.Transcript
import Shikumi.Cache (CachedResponse (CachedResponse), cachedLLM, currentKeyVersion)
import Shikumi.Cache.Backend.Memory (newMemoryCache, runCacheMemory)
import Shikumi.Effect.Time (runTime)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM (..), complete)
import Streamly.Data.Fold qualified as Fold
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "Baikai structured content"
    [ testCase "behavior trace preserves mixed structured data and absent provider observations" do
        events <- newIORef []
        let api = Custom "structured-behavior-trace"
            model = emptyModel & #api .~ api
            mixed = response & #message . #content .~ Vector.fromList [AssistantText (TextContent "answer"), AssistantData structured]
            handler _ _ _ = pure mixed
            sink = TraceSink (Fold.drainMapM (\event -> modifyIORef' events (<> [event])))
        registry <- newProviderRegistryFrom [apiProviderWith api (liftCompleteToStream handler) handler]
        base <- newBehaviorEnv
        let env = base & #providerRegistry .~ Just registry & #traceSink .~ Just sink
        actual <- completeBehaviorRequest env model Context.emptyContext emptyOptions
        actual.message.content @?= mixed.message.content
        actual.evidence @?= Nothing
        observed <- readIORef events
        [structuredData | CallFinished {structuredData} <- observed] @?= [Just (Vector.singleton structured)]
        length [() | CallStarted {} <- observed] @?= 1
        length [() | CallEvidence {} <- observed] @?= 0
        length [() | CallFailed {} <- observed] @?= 0,
      testCase "public full response codec retains data and optional provider observations" do
        parseEither responseFromJSON (responseToJSON response) @?= Right response,
      testCase "cache serialization preserves structured data without minting call evidence" do
        now <- getCurrentTime
        let evidence =
              Evidence.baseEvidence
                (Evidence.evidenceRequest "structured-cache")
                "original-call"
                (Evidence.EndpointIdentity "fixture" "fixture" Evidence.TransportHttpApi Nothing "fixture/1" Nothing)
                "fixture"
                Evidence.noThinkingRequested
                now
                now
                Evidence.CallSucceeded
                "sha256:request"
                "sha256:configuration"
            original = response & #evidence .~ Just evidence
            cached = CachedResponse original now currentKeyVersion
        parseEither responseFromJSON (responseToJSON original) @?= Right original
        eitherDecode (encode cached) @?= Right (CachedResponse response now currentKeyVersion)
        cache <- newMemoryCache
        count <- newIORef 0
        result <- runEff . runErrorNoCallStack @ShikumiError . runConcurrent . runTime . runCacheMemory cache . counting original count . cachedLLM $ do
          first <- complete emptyModel Context.emptyContext emptyOptions
          second <- complete emptyModel Context.emptyContext emptyOptions
          pure (first, second)
        result @?= Right (original, response)
        readIORef count >>= (@?= 1)
        case result of
          Right (_, hit) -> do
            hit.evidence @?= Nothing
            restored <- either (assertFailure . show) pure (restoreAssistant (captureAssistant original))
            restored.content @?= hit.message.content
          Left _ -> assertFailure "cache result missing",
      testCase "protected answer snapshot roundtrips optional fields and rejects invalid probability data" do
        snapshot <- either (assertFailure . show) (maybe (assertFailure "snapshot missing") pure) (captureAnswer response.message.content)
        eitherDecode (encode snapshot) @?= Right snapshot
        answerBlocks snapshot @?= [structured]
        show snapshot @?= "AnswerSnapshot <protected>"
        let invalid = structured {confidence = Just (Map.singleton "urgent" 1.1)}
        assertBool "invalid confidence refused" (isLeft (captureAnswer (Vector.singleton (AssistantData invalid))))
        captureAnswer (Vector.singleton (AssistantText (TextContent "legacy"))) @?= Right Nothing,
      testCase "snapshot decoder enforces format, block count and retained bytes" do
        let decode = eitherDecode @AnswerSnapshot . encode
        mapM_
          (assertBool "malformed snapshot refused" . isLeft . decode)
          [ object ["format" .= (2 :: Int), "blocks" .= [structured]],
            object ["format" .= (1 :: Int), "blocks" .= ([] :: [DataContent])],
            object ["format" .= (1 :: Int), "blocks" .= replicate 257 structured],
            object ["format" .= (1 :: Int), "blocks" .= [structured {value = object ["large" .= Text.replicate 1048576 "x"]}]]
          ],
      testCase "assistant replay selects version two and preserves structured content on restore" do
        let captured = captureAssistant response
        captured.format @?= StructuredAssistant
        eitherDecode (encode captured) @?= Right captured
        restored <- either (assertFailure . show) pure (restoreAssistant captured)
        restored.content @?= response.message.content
        assertBool "structured output cannot become successful empty prose" (isLeft (validateTerminalOutput defaultHarnessPolicy captured))
        show captured @?= "ReplayAssistant StructuredAssistant <protected>",
      testCase "legacy assistant bytes stay version one and cannot acquire structured blocks" do
        let legacy = captureAssistant (response & #message . #content .~ Vector.singleton (AssistantText (TextContent "legacy")))
        legacy.format @?= LegacyAssistant
        eitherDecode (encode legacy) @?= Right legacy
        let mixed = legacy & #blocks .~ [DataBlock structured]
        assertBool "historical structured data refused on decode" (isLeft (eitherDecode @ReplayAssistant (encode mixed)))
        assertBool "historical structured data refused on restore" (isLeft (restoreAssistant mixed)),
      testCase "the new structured byte bound does not narrow a historical text reader" do
        let legacy = captureAssistant (response & #message . #content .~ Vector.singleton (AssistantText (TextContent (Text.replicate 1048576 "x"))))
        eitherDecode (encode legacy) @?= Right legacy
        assertBool "historical text still restores" (not (isLeft (restoreAssistant legacy)))
        let structuredVersion = legacy & #format .~ StructuredAssistant
        assertBool "structured format retains its byte bound" (isLeft (eitherDecode @ReplayAssistant (encode structuredVersion))),
      testCase "structured user data requires context version three and remains in a user message" do
        let input = object ["ticket" .= ("Checkout unavailable" :: Text.Text)]
            request = RequestTurn [captureUserContent (UserData input)] Nothing
            context = ReplayContext StructuredContext Nothing [request]
        eitherDecode (encode context) @?= Right context
        restored <- either (assertFailure . show) pure (restoreContext context)
        case Vector.toList restored.messages of
          [Message.UserMessage payload] -> payload.content @?= Vector.singleton (UserData input)
          _ -> assertFailure "structured input changed message role"
        assertBool "old request format refuses user data" (isLeft (restoreContext (context & #format .~ RequestContext)))
        let assistant = captureAssistant response & #blocks .~ [UserDataBlock input]
        assertBool "user data is invalid in an assistant snapshot" (isLeft (eitherDecode @ReplayAssistant (encode assistant)))
        let misplaced = context & #messages .~ [RequestTurn [DataBlock structured] Nothing]
        assertBool "assistant data is invalid in a user request" (isLeft (restoreContext misplaced))
    ]

structured :: DataContent
structured =
  DataContent
    (object ["urgent" .= True, "category" .= ("technical" :: Text.Text), "severity" .= (1.5 :: Double)])
    (Just (Map.fromList [("urgent", Map.singleton "true" 0.83), ("category", Map.fromList [("billing", 0.2), ("technical", 0.7)])]))
    (Just (Map.singleton "category" 0.65))
    (Just "public-fixture-method")

response :: Response
response = emptyResponse & #message . #content .~ Vector.singleton (AssistantData structured)

counting :: (IOE :> es, Error ShikumiError :> es) => Response -> IORef Int -> Eff (LLM : es) a -> Eff es a
counting original count = interpret \_ -> \case
  Complete {} -> liftIO (modifyIORef' count (+ 1)) >> pure original
  Stream {} -> throwError (ValidationFailure "unexpected stream in complete-cache fixture")
