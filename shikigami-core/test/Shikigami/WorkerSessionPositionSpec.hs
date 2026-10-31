module Shikigami.WorkerSessionPositionSpec (tests) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft)
import Data.Text (Text)
import Shikigami.StateRevision (initialRevision)
import Shikigami.WorkerSession.Capability (WorkerCommand (InspectWorker, ReadWorkerEvents))
import Shikigami.WorkerSession.Position
import Shikigami.WorkerSession.Types (WorkerSessionId (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "worker session positions"
    [ testCase "before-first and message positions retain numeric bytes" do
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
