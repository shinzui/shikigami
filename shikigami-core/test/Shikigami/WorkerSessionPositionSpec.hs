module Shikigami.WorkerSessionPositionSpec (tests) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.StateRevision (initialRevision)
import Shikigami.WorkerSession.Capability (WorkerCommand (InspectWorker, ReadWorkerEvents), WorkerInstruction (..))
import Shikigami.WorkerSession.Input
import Shikigami.WorkerSession.Position
import Shikigami.WorkerSession.Types (WorkerSessionId (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "worker session positions"
    [ testCase "worker instruction preserves protected Unicode text and exact command bytes" do
        let text = "  続ける PRIVATE_INSTRUCTION  "
        checked <- either (assertFailure . show) pure (parseInstructionText text)
        let draft = WorkerInstruction checked initialRevision initialRevision initialRevision Nothing
            expected = Aeson.object ["text" .= text, "objectiveRevision" .= (0 :: Integer), "assignmentRevision" .= (0 :: Integer), "criteriaRevision" .= (0 :: Integer), "selection" .= Aeson.Null]
        Aeson.eitherDecode (Aeson.encode draft) @?= Right draft
        Aeson.encode draft @?= Aeson.encode expected
        instructionText checked @?= text
        assertBool "protected text does not appear in Show" (not ("PRIVATE_INSTRUCTION" `Text.isInfixOf` Text.pack (show checked)))
        mapM_ (\bad -> assertBool "blank or oversized text is refused" (isLeft (parseInstructionText bad))) ["", " \n\t", Text.replicate 349526 "あ"]
        assertBool "invalid command text is refused at decode" (isLeft (Aeson.eitherDecode @WorkerInstruction "{\"text\":\" \" ,\"objectiveRevision\":0,\"assignmentRevision\":0,\"criteriaRevision\":0}")),
      testCase "session limits preserve numeric bytes and reject each invalid bound" do
        checkLimit maximumSessionCapacity 128
        checkLimit (checkedLimit 1000 :: MaximumAssignments) 1000
        checkLimit (checkedLimit 128 :: MailboxLimit) 128,
      testCase "before-first and message positions retain numeric bytes" do
        Aeson.encode beforeMessages @?= Aeson.encode (-1 :: Integer)
        Aeson.eitherDecode (Aeson.encode (-1 :: Integer)) @?= Right beforeMessages
        Aeson.eitherDecode (Aeson.encode (0 :: Integer)) @?= Right (afterMessage initialRevision)
        assertBool "another negative position is refused" (isLeft (parseMessagePosition (-2)))
        assertBool "negative JSON position is refused" (isLeft (Aeson.eitherDecode @MessagePosition (Aeson.encode (-2 :: Integer)))),
      testCase "assignment inspection keeps its exact after wire field" do
        let command = InspectWorker session beforeMessages 10
            expected = wire "InspectWorker" (-1) 10
        Aeson.toJSON command @?= expected
        Aeson.encode command @?= Aeson.encode expected
        Aeson.fromJSON expected @?= Aeson.Success command
        case expected of
          Aeson.Object fields -> do
            let wrongField = Aeson.Object (KeyMap.insert "position" (Aeson.toJSON (-1 :: Integer)) (KeyMap.delete "after" fields))
            assertBool "internal field name is not admitted on the wire" (case Aeson.fromJSON wrongField :: Aeson.Result WorkerCommand of Aeson.Error _ -> True; _ -> False)
          _ -> assertFailure "wire control was not an object",
      testCase "event reads keep the same numeric after contract" do
        let command = ReadWorkerEvents session initialRevision 10
            expected = wire "ReadWorkerEvents" 0 10
        Aeson.toJSON command @?= expected
        Aeson.encode command @?= Aeson.encode expected
        Aeson.fromJSON expected @?= Aeson.Success command
    ]
  where
    session = WorkerSessionId "fixture-session"
    wire :: Text -> Integer -> Int -> Aeson.Value
    wire tag after limit = Aeson.object ["tag" .= tag, "sessionId" .= session, "after" .= after, "limit" .= limit]

checkedLimit :: (SessionLimit a) => Integer -> a
checkedLimit value = either (error . show) id (parseSessionLimit value)

checkLimit :: forall a. (SessionLimit a, Aeson.ToJSON a, Aeson.FromJSON a, Eq a, Show a) => a -> Integer -> Assertion
checkLimit value upper = do
  Aeson.eitherDecode (Aeson.encode value) @?= Right value
  Aeson.encode value @?= Aeson.encode upper
  mapM_ (\bad -> assertBool "invalid bound refused" (isLeft (Aeson.eitherDecode @a (Aeson.encode (bad :: Integer))))) [0, upper + 1]
