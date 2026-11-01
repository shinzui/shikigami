{-# LANGUAGE DataKinds #-}

module Shikigami.WorkspaceSystemdSpec (tests) where

import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as ClaimText
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity (CompatibilityIdentity))
import Shikigami.Execution.Claim qualified as Claim
import Shikigami.Execution.Identity
import Shikigami.Execution.Payload (PayloadDigest, parsePayloadDigest)
import Shikigami.Execution.Transcript (ExecutionId (..), NextWork (NeedModel), executionIdentity)
import Shikigami.Fixture.ExecutionIdentity (fixtureAttemptId, fixtureOperationId)
import Shikigami.Prelude ((&), (.~))
import Shikigami.StateRevision qualified as Generation
import Shikigami.Workspace.Process
import Shikigami.Workspace.Systemd
import Shikigami.Workspace.Value
import System.Info qualified as Platform
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "workspace systemd transport"
    [ testCase "argv preserves literal arguments and explicitly constructs the isolated environment" $ withRecord \profile record -> do
        argv <- right =<< arguments now profile record
        dropWhile (/= "--") argv @?= ["--", "/bin/deadline", "1", show (floor (utcTimeToPOSIXSeconds record.deadline * 1000000000) :: Integer), "--", "/bin/env", "-i", "HOME=/scratch", "/bin/validate", "$HOME", "%n", "", "line\né"]
        assertBool "disable manager expansion" ("--expand-environment=no" `elem` argv)
        assertBool "bounded deadline" ("RuntimeMaxSec=30" `elem` argv)
        assertBool "never use command text as service diagnostics" (("Description=shikigami-workspace/1 " <> Text.unpack (workspaceCoordinateText record.fingerprint)) `elem` argv),
      testCase "launch time consumes the accepted deadline and never extends it" $ withRecord \profile record -> do
        argv <- right =<< arguments (addUTCTime 0.5 now) profile record
        assertBool "fractional remaining time is rounded down" ("RuntimeMaxSec=29" `elem` argv)
        arguments (addUTCTime 30 now) profile record >>= (@?= Left SystemdRefused)
        arguments (addUTCTime (-2) now) profile record >>= (@?= Left SystemdRefused)
        collectorArguments (addUTCTime 30 now) profile "/private/operation" record @?= Left SystemdRefused,
      testCase "changed root, Unix identity, collector and environment helper invalidate the accepted profile" $ withRecord \profile record -> do
        assertBool "root identity refuses at scalar admission" (case parseWorkspaceIdentity 0 of Left _ -> True; _ -> False)
        mapM_
          (\changed -> arguments now changed record >>= (@?= Left SystemdRefused))
          [ profile & #rootDirectory .~ (workspaceLocator "/other/root"),
            profile & #rootIdentity .~ otherDigest,
            profile & #userId .~ ((either (error . show) id . parseWorkspaceIdentity) 62002),
            profile & #groupId .~ ((either (error . show) id . parseWorkspaceIdentity) 62002),
            profile & #environmentExecutable .~ (workspaceLocator "/other/env"),
            profile & #deadlineExecutable .~ (workspaceLocator "/other/deadline"),
            profile & #collectorExecutable .~ (workspaceLocator "/other/collector")
          ]
        mapM_
          ( \unsafe -> do
              identity <- systemdProfileIdentity unsafe
              arguments now unsafe (record & #command . #profile .~ identity) >>= (@?= Left SystemdRefused)
          )
          [profile & #rootDirectory .~ (workspaceLocator "/unsafe/../root"), profile & #rootDirectory .~ (workspaceLocator "/unsafe/%n"), profile & #rootIdentity .~ (workspaceCoordinate "invalid"), profile & #deadlineExecutable .~ (workspaceLocator "/workspace/deadline"), profile & #environmentExecutable .~ (workspaceLocator "/scratch/env")],
      testCase "only the committed pre-launch shape can be serialized for a new start" $ withRecord \profile record -> do
        mapM_
          (\phase -> arguments now profile (record & #phase .~ phase) >>= (@?= Left SystemdRefused))
          [ProcessReserved, ProcessRunning, ProcessSettled, ProcessRefused, ProcessUnresolved]
        arguments now profile (record & #invocationId .~ Just (workspaceCoordinate ("22222222222222222222222222222222"))) >>= (@?= Left SystemdRefused)
        arguments now profile (record & #bootId .~ Nothing) >>= (@?= Left SystemdRefused)
        arguments now profile (record & #routing .~ Nothing) >>= (@?= Left SystemdRefused)
        arguments now profile (record & #unit .~ (workspaceCoordinate ("arbitrary.service"))) >>= (@?= Left SystemdRefused)
        arguments now profile (record & #command . #directory .~ (workspaceCoordinate "../outside")) >>= (@?= Left SystemdRefused),
      testCase "native unsupported hosts refuse without touching private paths or launching a service" $ withRecord \profile record -> do
        if Platform.os == "linux"
          then pure ()
          else do
            systemdBootIdentity >>= (@?= Left SystemdUnsupported)
            startCollector profile "/missing/metadata" record >>= (@?= Left SystemdUnsupported)
            startProcess profile "/missing/files" "/missing/scratch" "/missing/metadata" record >>= (@?= Left SystemdUnsupported)
    ]

arguments :: UTCTime -> SystemdProfile -> ProcessRecord -> IO (Either SystemdError [String])
arguments time profile = processArguments time profile "/private/files" "/private/scratch" "/private/operation"

withRecord :: (SystemdProfile -> ProcessRecord -> IO a) -> IO a
withRecord use = do
  let profile = SystemdProfile (workspaceLocator "/private/root") digest (workspaceLocator "/bin/env") (workspaceLocator "/bin/deadline") (workspaceLocator "/bin/shikigami-workspace-collector") ((either (error . show) id . parseWorkspaceIdentity) 62001) ((either (error . show) id . parseWorkspaceIdentity) 62001)
  identity <- systemdProfileIdentity profile
  let command = ProcessCommand (workspaceCoordinate "validate") identity (workspaceCoordinate "/bin/validate") [(workspaceCoordinate "$HOME"), (workspaceCoordinate "%n"), (workspaceCoordinate ""), (workspaceCoordinate "line\né")] (workspaceCoordinate "") (Map.singleton (workspaceCoordinate "HOME") (workspaceCoordinate "/scratch")) ((either (error . show) id . parseProcessSeconds) 30) ((either (error . show) id . parseProcessOutputBytes) 1024)
      operation = fixtureOperationId "process-operation"
      record = ProcessRecord operation (fixtureAttemptId "original-attempt") (fixtureOwner "claim") (fixtureGeneration 1) digest digest digest command (addUTCTime 30 now) (processUnit operation digest) (Just (workspaceCoordinate ("11111111-1111-4111-8111-111111111111"))) Nothing ProcessLaunchRequested Nothing (Just (ProcessRouting ProcessRoutingV1 (executionIdentity "transport-execution") (CompatibilityIdentity (fixtureAgentName "worker")) (fixturePayloadDigest (workspaceCoordinateText digest)) NeedModel))
  use profile record

now :: UTCTime
now = read "2026-10-29 00:00:00 UTC"

digest, otherDigest :: WorkspaceCoordinate scope
digest = workspaceCoordinate ("sha256:" <> Text.replicate 64 "a")
otherDigest = workspaceCoordinate ("sha256:" <> Text.replicate 64 "b")

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure

fixtureGeneration :: Integer -> Generation.StateRevision "execution-attempt"
fixtureGeneration value = either (error . show) id (Generation.parseRevision value)

fixtureOwner :: ClaimText.Text -> Claim.ClaimOwner
fixtureOwner value = either (error . show) id (Claim.parseClaimOwner value)

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

fixturePayloadDigest :: Text -> PayloadDigest
fixturePayloadDigest = either (error . show) id . parsePayloadDigest
