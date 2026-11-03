module Shikigami.BaikaiStructuredContentSpec (tests) where

import Baikai.Content (AssistantContent (..), DataContent (..), TextContent (..), UserContent (..))
import Baikai.Context qualified as Context
import Baikai.Message qualified as Message
import Baikai.Model (emptyModel)
import Baikai.Options (emptyOptions)
import Baikai.Response (Response (..), emptyResponse)
import Baikai.Response.JSON (responseFromJSON, responseToJSON)
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
import Shikigami.Decision.Answer
import Shikigami.Execution.Policy (defaultHarnessPolicy, validateTerminalOutput)
import Shikigami.Execution.Transcript
import Shikumi.Cache (CachedResponse (CachedResponse), cachedLLM, currentKeyVersion)
import Shikumi.Cache.Backend.Memory (newMemoryCache, runCacheMemory)
import Shikumi.Effect.Time (runTime)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM (..), complete)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "Baikai structured content"
    [ testCase "public full response codec retains data and optional provider observations" do
        parseEither responseFromJSON (responseToJSON response) @?= Right response,
      testCase "cache serialization preserves structured data without minting call evidence" do
        now <- getCurrentTime
        let cached = CachedResponse response now currentKeyVersion
        eitherDecode (encode cached) @?= Right cached
        cache <- newMemoryCache
        count <- newIORef 0
        result <- runEff . runErrorNoCallStack @ShikumiError . runConcurrent . runTime . runCacheMemory cache . counting count . cachedLLM $ do
          first <- complete emptyModel Context.emptyContext emptyOptions
          second <- complete emptyModel Context.emptyContext emptyOptions
          pure (first, second)
        result @?= Right (response, response)
        readIORef count >>= (@?= 1)
        case result of
          Right (_, hit) -> hit.evidence @?= Nothing
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

counting :: (IOE :> es, Error ShikumiError :> es) => IORef Int -> Eff (LLM : es) a -> Eff es a
counting count = interpret \_ -> \case
  Complete {} -> liftIO (modifyIORef' count (+ 1)) >> pure response
  Stream {} -> throwError (ValidationFailure "unexpected stream in complete-cache fixture")
