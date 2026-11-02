module Shikigami.ObjectiveTrackerReiSpec (requireIsolatedRei, tests, dispatchChild) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket_)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.Generics.Labels ()
import Data.IORef
import Data.KindID qualified as KindID
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Effectful (Eff)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types qualified as HttpTypes
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import Rei.Api qualified as Api
import Rei.Api.Id qualified as Id
import Rei.Api.Problem qualified as Result
import Rei.Client qualified as Client
import Rei.Intention.Api qualified as Intention
import Rei.Intention.Wire qualified as Wire
import Shikigami.Action.Authorization (allowAllActionAuthorizerForTests)
import Shikigami.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Shikigami.App.Config (mkByteLimit)
import Shikigami.Execution.Identity (OperationId, parseOperationId)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Objective.Capability qualified as O
import Shikigami.Objective.Command qualified as OC
import Shikigami.Objective.Tracker.Command qualified as C
import Shikigami.Objective.Tracker.Config
import Shikigami.Objective.Tracker.Dispatch qualified as Dispatch
import Shikigami.Objective.Tracker.Mapping (supportedMappingRevision)
import Shikigami.Objective.Tracker.Provider qualified as P
import Shikigami.Objective.Tracker.Rei qualified as Rei
import Shikigami.Objective.Tracker.Runtime qualified as Runtime
import Shikigami.Objective.Tracker.Store qualified as S
import Shikigami.Objective.Tracker.Types
import Shikigami.Objective.Types qualified as OT
import Shikigami.Prelude
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.Sink.Http (HttpLimits (..))
import Shikigami.StateRevision
import System.Environment (getEnv, getExecutablePath, setEnv, unsetEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hClose)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, waitForProcess)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

data IsolatedRei = IsolatedRei {baseUrl :: !Text, token :: !Client.BearerToken, resource :: !ResourceId}

-- This suite cannot select a user's default server or silently skip the live
-- gate. The launcher owns its server, DB, credentials and disposable intention.
requireIsolatedRei :: IO IsolatedRei
requireIsolatedRei = do
  marker <- getEnv "SHIKIGAMI_TEST_REI_ISOLATED"
  unless (marker == "masterplan-18") (fail "run this suite through tests/objective-trackers/with-rei.sh")
  baseUrl <- Text.pack <$> getEnv "SHIKIGAMI_TEST_REI_BASE_URL"
  unless ("http://127.0.0.1:" `Text.isPrefixOf` baseUrl) (fail "live Rei qualification requires the disposable loopback server")
  token <- right . Client.mkBearerToken . Text.pack =<< getEnv "SHIKIGAMI_TEST_REI_TOKEN"
  resource <- right . parseCoordinate . Text.pack =<< getEnv "SHIKIGAMI_TEST_REI_INTENTION"
  pure IsolatedRei {baseUrl, token, resource}

tests :: DatabaseFixture -> IsolatedRei -> TestTree
tests fixture isolated =
  testGroup
    "ObjectiveTrackerRei"
    [ testCase "real read and action traverse the retained production executor" $
        withHost fixture isolated isolated.token \env objective host selected client _ -> do
          bindings <- right =<< run env (S.inspectBindings host objective)
          length bindings @?= 1
          forM_ bindings \binding -> assertBool "ordered source position" (isJust binding.latest.position)
          (intent, _) <- enqueue env objective host
          run env (Dispatch.dispatch host objective intent.publicationId) >>= (@?= Right Dispatch.Settled)
          (_, receipt) <- single =<< right =<< run env (S.inspectPublications host objective (key "binding"))
          receipt.state @?= Delivered
          evidence <- maybe (assertFailure "missing authoritative action acknowledgement" >> fail "unreachable") pure receipt.evidence
          evidence.kind @?= ProviderProved
          attempt <- maybe (fail "missing attempt") pure receipt.attempt
          verified <- waitFor 100 (selected.verifyReceipt intent attempt evidence.remoteReceiptId) isJust
          fmap (.digest) verified @?= Just intent.digest
          candidates <- right =<< Rei.candidateReceipts client intent
          assertBool "bounded real action pages contain the acknowledged receipt" (evidence.remoteReceiptId `elem` candidates),
      testCase "real bearer refusal leaves the local objective committed and the remote receipt rejected" do
        invalid <- right (Client.mkBearerToken "invalid-fixture-token")
        withHost fixture isolated invalid \env objective host _ _ _ -> do
          (intent, _) <- enqueue env objective host
          run env (Dispatch.dispatch host objective intent.publicationId) >>= (@?= Right Dispatch.Settled)
          (_, receipt) <- single =<< right =<< run env (S.inspectPublications host objective (key "binding"))
          receipt.state @?= Rejected
          current <- right =<< run env (O.readObjective objectiveHost objective)
          current.status @?= OT.Blocked,
      testCase "committed response loss survives process restart and requires exact operator attestation" $
        withProxy isolated LoseAcknowledgement \endpoint posts remoteIds _ ->
          withHostAt fixture isolated endpoint isolated.token \env objective host selected client connectionString -> do
            (intent, _) <- enqueue env objective host
            child connectionString host.settings objective intent.publicationId
            (_, unknown) <- single =<< right =<< run env (S.inspectPublications host objective (key "binding"))
            unknown.state @?= Unknown
            child connectionString host.settings objective intent.publicationId
            readIORef posts >>= (@?= 1)
            remote <- single =<< readIORef remoteIds
            candidates <- waitFor 100 (Rei.candidateReceipts client intent) (\case Right values -> remote `elem` values; _ -> False)
            candidates @?= Right [remote]
            attempt <- maybe (fail "missing attempt") pure unknown.attempt
            selected.reconcile intent attempt >>= (@?= P.StillUnknown)
            _ <- right =<< run env (Dispatch.verifyDelivery host objective intent.publicationId remote)
            let attest receiptId digest = C.AttestDelivery intent.publicationId attempt.attemptId intent.scope.incarnation receiptId digest unknown.revision (checked (OT.parseInstructions "verified exact remote action after response loss"))
            wrong <- run env (S.execute host objective (operation "wrong-receipt") (attest (key "action_forged") intent.digest))
            assertBool "forged remote receipt refused" (either (const True) (const False) wrong)
            _ <- right =<< run env (S.execute host objective (operation "attest") (attest remote intent.digest))
            (_, delivered) <- single =<< right =<< run env (S.inspectPublications host objective (key "binding"))
            delivered.state @?= Delivered
            fmap (.kind) delivered.evidence @?= Just OperatorAttested
            child connectionString host.settings objective intent.publicationId
            readIORef posts >>= (@?= 1),
      testGroup
        "real proxy failure channels"
        [ testCase (show status) $
            withProxy isolated (Refuse status) \endpoint posts _ _ ->
              withHostAt fixture isolated endpoint isolated.token \env objective host _ _ _ -> do
                (intent, _) <- enqueue env objective host
                _ <- right =<< run env (Dispatch.dispatch host objective intent.publicationId)
                (_, receipt) <- single =<< right =<< run env (S.inspectPublications host objective (key "binding"))
                receipt.state @?= expected
                _ <- run env (Dispatch.dispatch host objective intent.publicationId)
                readIORef posts >>= (@?= 0)
        | (status, expected) <- [(400, Rejected), (401, Rejected), (403, Rejected), (404, Rejected), (422, Rejected), (409, Conflict), (429, Unknown), (500, Unknown), (503, Unknown)]
        ],
      testCase "a paused binding and revoked export grant send no POST" $
        withProxy isolated PassThrough \endpoint posts _ _ ->
          withHostAt fixture isolated endpoint isolated.token \env objective host _ _ _ -> do
            (intent, _) <- enqueue env objective host
            let revoked = host & #settings . #connections .~ [connection & #exportGrants .~ [] | connection <- host.settings.connections]
            _ <- right =<< run env (Dispatch.dispatch revoked objective intent.publicationId)
            (_, receipt) <- single =<< right =<< run env (S.inspectPublications host objective (key "binding"))
            receipt.state @?= Suppressed
            _ <- right =<< run env (S.execute host objective (operation "pause") (C.Pause (key "binding") initialRevision))
            _ <- right =<< run env (O.executeCommand objectiveHost objective (advanceRevision initialRevision) (operation "unblock") (OC.SetBlocked OT.Unblocked))
            readIORef posts >>= (@?= 0),
      testCase "authoritative action acknowledgement stays delivered while intention reads lag" $
        withProxy isolated LagReads \endpoint posts _ _ ->
          withHostAt fixture isolated endpoint isolated.token \env objective host _ _ _ -> do
            baseline <- single =<< right =<< run env (S.inspectBindings host objective)
            (intent, _) <- enqueue env objective host
            _ <- right =<< run env (Dispatch.dispatch host objective intent.publicationId)
            _ <- right =<< run env (S.observe host objective baseline.bindingId)
            observed <- single =<< right =<< run env (S.inspectBindings host objective)
            observed.latest.position @?= baseline.latest.position
            (_, receipt) <- single =<< right =<< run env (S.inspectPublications host objective baseline.bindingId)
            receipt.state @?= Delivered
            _ <- right =<< run env (Dispatch.dispatch host objective intent.publicationId)
            readIORef posts >>= (@?= 1),
      testCase "candidate discovery preserves scoped cursors across bounded real action pages" $
        withProxy isolated PassThrough \endpoint _ _ gets ->
          withHostAt fixture isolated endpoint isolated.token \env objective host _ client _ -> do
            (intent, _) <- enqueue env objective host
            before <- readIORef gets
            candidates <- Rei.candidateReceipts client (intent & #scope . #resourceId .~ isolated.resource)
            candidates @?= Right []
            after <- readIORef gets
            assertBool "fixture requires multiple pages, within four-page bound" (after - before > 1 && after - before <= 4),
      testCase "production composition resolves only the named fixture credential and bounds real response bodies" $
        withHost fixture isolated isolated.token \env objective host _ client _ -> do
          binding <- single =<< right =<< run env (S.inspectBindings host objective)
          intention <- right (Id.parseIntentionIdPiece (coordinateText binding.scope.resourceId))
          changed <- Client.runReiClient client (Intention.setNoteGuidance (Api.intentionCommands Client.reiClient) (Client.bearerAuth isolated.token) intention (Wire.NoteGuidanceRequest (Text.replicate 4096 "x")))
          case changed of Right Result.ReiOk {} -> pure (); _ -> fail "real bounded-response fixture mutation failed"
          provider0 <- right =<< host.providerFor binding.scope
          _ <- waitFor 100 (provider0.readResource binding.scope) (\case P.Observed observed -> Text.length (OT.instructionsText observed.snapshot.instructions) == 4096; _ -> False)
          token <- getEnv "SHIKIGAMI_TEST_REI_TOKEN"
          let name = "SHIKIGAMI_TEST_REI_RUNTIME_TOKEN"
              configured = host.settings & #connections .~ [connection & #credential .~ Just (key ("env:" <> Text.pack name)) | connection <- host.settings.connections]
          bracket_ (setEnv name token) (unsetEnv name) $
            Runtime.withTrackerProviders (HttpLimits (checked (mkByteLimit 65536)) (checked (mkByteLimit 1048576))) configured \built -> do
              providers <- right built
              connection <- single host.settings.connections
              let scope = binding.scope
              provider <- right =<< Runtime.providerFor providers configured scope
              provider.readResource scope >>= \case P.Observed _ -> pure (); _ -> fail "production provider failed real read"
              let redirected = configured & #connections .~ [connection & #endpoint .~ "http://127.0.0.1:1"]
              Runtime.providerFor providers redirected scope >>= \case Left TrackerConflict -> pure (); _ -> fail "cached credentials must not follow changed connection targets"
          bracket_ (setEnv name token) (unsetEnv name) $
            Runtime.withTrackerProviders (HttpLimits (checked (mkByteLimit 65536)) (checked (mkByteLimit 1024))) configured \built -> do
              providers <- right built
              let scope = binding.scope
              provider <- right =<< Runtime.providerFor providers configured scope
              provider.readResource scope >>= (@?= P.ReadUnavailable)
          Runtime.withTrackerProviders (HttpLimits (checked (mkByteLimit 65536)) (checked (mkByteLimit 1048576))) (configured & #enabled .~ TrackersDisabled) \built -> do
            _ <- right built
            pure (),
      testCase "real note guidance becomes a proposal and action-only advances do not invent changes" $
        withHost fixture isolated isolated.token \env objective host selected client _ -> do
          binding <- single =<< right =<< run env (S.inspectBindings host objective)
          intention <- right (Id.parseIntentionIdPiece (coordinateText binding.scope.resourceId))
          changed <- Client.runReiClient client (Intention.setNoteGuidance (Api.intentionCommands Client.reiClient) (Client.bearerAuth isolated.token) intention (Wire.NoteGuidanceRequest "new remote guidance"))
          case changed of Right Result.ReiOk {} -> pure (); _ -> fail "real guidance mutation failed"
          _ <- waitFor 100 (selected.readResource binding.scope) (\case P.Observed observation -> OT.instructionsText observation.snapshot.instructions == "new remote guidance"; _ -> False)
          _ <- right =<< run env (S.observe host objective (key "binding"))
          proposals <- right =<< run env (S.inspectProposals host objective (key "binding"))
          length (filter ((== AwaitingDecision) . (.state)) proposals) @?= 1
          current <- right =<< run env (O.readObjective objectiveHost objective)
          current.instructions @?= request.instructions
          (intent, _) <- enqueue env objective host
          _ <- right =<< run env (Dispatch.dispatch host objective intent.publicationId)
          _ <- waitFor 100 (selected.readResource binding.scope) (\case P.Observed observation -> observation.position > binding.latest.position; _ -> False)
          _ <- right =<< run env (S.observe host objective (key "binding"))
          after <- right =<< run env (S.inspectProposals host objective (key "binding"))
          length (filter ((== AwaitingDecision) . (.state)) after) @?= 1
    ]

withHost :: DatabaseFixture -> IsolatedRei -> Client.BearerToken -> (AppEnv -> OT.ObjectiveId -> S.TrackerHost -> P.Provider -> Client.ClientEnv -> Text -> IO a) -> IO a
withHost fixture isolated = withHostAt fixture isolated isolated.baseUrl

withHostAt :: DatabaseFixture -> IsolatedRei -> Text -> Client.BearerToken -> (AppEnv -> OT.ObjectiveId -> S.TrackerHost -> P.Provider -> Client.ClientEnv -> Text -> IO a) -> IO a
withHostAt fixture isolated endpoint token callback = withShikigamiFreshDatabase fixture \connectionString -> do
  tracer <- noopTracer
  let env = AppEnv (defaultConnectionSettings connectionString) tracer Nothing Nothing
  _ <- right =<< run env Catalog.registerProjectionCatalog
  manager <- newManager defaultManagerSettings
  base <- Client.parseBaseUrl (Text.unpack isolated.baseUrl)
  target <- Client.parseBaseUrl (Text.unpack endpoint)
  let setupClient = Client.mkClientEnv manager base
      client = Client.mkClientEnv manager target
  createdRemote <-
    Client.runReiClient setupClient (Intention.createIntention (Api.intentionCommands Client.reiClient) (Client.bearerAuth isolated.token) (Wire.defaultCreateIntentionRequest "Shikigami disposable tracker qualification" Nothing Nothing)) >>= \case
      Right (Result.ReiOk value) -> pure value
      _ -> fail "could not create the disposable Rei intention through its real API"
  let remoteId = key (KindID.toText createdRemote.intentionId)
      scope = ResourceScope (key "rei-fixture") (key "isolated-installation") remoteId Rei.reiProviderRevision
      connection = Connection scope.connectionId scope.incarnation scope.providerRevision endpoint (key "fixture-human-account") Nothing [actor] [actor]
      settings = TrackerSettings TrackersEnabled [connection] 60 20 [actor]
  selected <- right (Rei.mkReiProvider client token scope)
  let host = S.TrackerHost objectiveHost settings (\requested -> pure (if requested == scope then Right selected else Left TrackerDenied))
  created <- right =<< run env (O.createObjective objectiveHost (operation "create") Nothing request)
  _ <- waitFor 100 (selected.readResource scope) (\case P.Observed _ -> True; _ -> False)
  _ <- right =<< run env (S.execute host created.objectiveId (operation "bind") (C.Bind (key "binding") scope (FieldPolicy supportedMappingRevision ProposeField ProposeField ProgressSummaries)))
  callback env created.objectiveId host selected client connectionString

enqueue :: AppEnv -> OT.ObjectiveId -> S.TrackerHost -> IO (PublicationIntent, PublicationReceipt)
enqueue env objective host = do
  _ <- right =<< run env (O.executeCommand objectiveHost objective initialRevision (operation "progress") (OC.SetBlocked OT.IsBlocked))
  single =<< right =<< run env (S.inspectPublications host objective (key "binding"))

actor :: OT.AccessPrincipal
actor = OT.LocalOperator (checked (OT.parseOperatorId "fixture-operator"))

objectiveHost :: O.ObjectiveHost
objectiveHost = O.ObjectiveHost (OT.defaultObjectiveSettings & #enabled .~ OT.ObjectivesEnabled & #operator .~ Just (checked (OT.parseOperatorId "fixture-operator"))) (pure (Right actor)) allowAllActionAuthorizerForTests (\_ _ -> pure (Right ())) (\_ _ -> pure (Right ())) (\_ -> pure (Left OT.ObjectiveInvalidEvidence))

request :: OT.CreateRequest
request = OT.CreateRequest (checked (OT.parseTitle "local fixture")) (checked (OT.parseGoal "qualify a real Rei action")) (checked (OT.parseInstructions "PRIVATE local instructions")) [OT.Criterion (checked (OT.parseCriterionKey "review")) (checked (OT.parseCriterionDescription "review the result")) OT.HumanVerifiable OT.JourneyOptional] []

key :: Text -> TrackerCoordinate scope
key = checked . parseCoordinate

operation :: Text -> OperationId
operation = checked . parseOperationId

checked :: (Show e) => Either e a -> a
checked = either (error . show) id

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure

single :: [a] -> IO a
single [value] = pure value
single _ = fail "expected one retained publication"

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = right =<< runAppIO env action

waitFor :: Int -> IO a -> (a -> Bool) -> IO a
waitFor remaining action accepted = do
  result <- action
  if accepted result then pure result else if remaining <= 0 then fail "Rei projection did not converge within the bounded poll" else threadDelay 100000 >> waitFor (remaining - 1) action accepted

-- This proxy forwards to the disposable production server. It can lose an
-- authoritative POST reply after commit, while retaining only action IDs for
-- the assertion; it does not implement a substitute Rei protocol.
data ProxyMode = PassThrough | LoseAcknowledgement | LagReads | Refuse Int

withProxy :: IsolatedRei -> ProxyMode -> (Text -> IORef Int -> IORef [RemoteReceiptId] -> IORef Int -> IO a) -> IO a
withProxy isolated mode callback = do
  manager <- newManager defaultManagerSettings
  posts <- newIORef 0
  identifiers <- newIORef []
  gets <- newIORef 0
  priorRead <- newIORef Nothing
  let application request respond = do
        body <- Wai.strictRequestBody request
        let actionPost = Wai.requestMethod request == "POST" && "/actions" `Text.isSuffixOf` Text.decodeUtf8 (Wai.rawPathInfo request)
        case (actionPost, mode) of
          (True, Refuse code) -> respond (Wai.responseLBS (HttpTypes.mkStatus code "fixture") [("Content-Type", "application/problem+json")] (Aeson.encode (Result.ProblemDetails "about:blank" "fixture refusal" code "controlled refusal before forwarding" "fixture_refusal" False Nothing)))
          _ -> do
            upstream <- Http.parseRequest (Text.unpack isolated.baseUrl <> Lazy.unpack (Lazy.fromStrict (Wai.rawPathInfo request <> Wai.rawQueryString request)))
            reply <- Http.httpLbs upstream {Http.method = Wai.requestMethod request, Http.requestHeaders = filter ((/= "Host") . fst) (Wai.requestHeaders request), Http.requestBody = Http.RequestBodyLBS body, Http.redirectCount = 0, Http.checkResponse = \_ _ -> pure ()} manager
            when (Wai.requestMethod request == "GET") (modifyIORef' gets (+ 1))
            when actionPost do
              modifyIORef' posts (+ 1)
              case Aeson.eitherDecode (Http.responseBody reply) of
                Right (value :: Wire.ActionWriteView) -> modifyIORef' identifiers (<> [key (KindID.toText value.actionId)])
                Left _ -> fail "proxy did not receive the real action acknowledgement"
            let currentReply = (Http.responseStatus reply, filter ((/= "Transfer-Encoding") . fst) (Http.responseHeaders reply), Http.responseBody reply)
                intentionRead = Wai.requestMethod request == "GET" && length (Wai.pathInfo request) == 4 && "intentions" `elem` Wai.pathInfo request
            visible <- case (mode, intentionRead) of
              (LagReads, True) -> do
                old <- readIORef priorRead
                sent <- readIORef posts
                if sent > 0 then pure (fromMaybe currentReply old) else writeIORef priorRead (Just currentReply) >> pure currentReply
              _ -> pure currentReply
            case (actionPost, mode) of
              (True, LoseAcknowledgement) -> respond (Wai.responseLBS (Http.responseStatus reply) [("Content-Type", "application/json")] "{lost-after-commit")
              _ -> let (status, headers, payload) = visible in respond (Wai.responseLBS status headers payload)
  Warp.testWithApplication (pure application) \port -> callback ("http://127.0.0.1:" <> Text.pack (show port)) posts identifiers gets

child :: Text -> TrackerSettings -> OT.ObjectiveId -> PublicationId -> IO ()
child connection settings objective publication = do
  executable <- getExecutablePath
  (Just input, Nothing, Nothing, process) <- createProcess (proc executable ["--tracker-dispatch-and-exit", "+RTS", "-N2", "-RTS"]) {std_in = CreatePipe, std_out = NoStream, std_err = Inherit}
  Lazy.hPutStrLn input (Aeson.encode (connection, settings, objective, publication))
  hClose input
  waitForProcess process >>= (@?= ExitFailure 91)

dispatchChild :: IO ()
dispatchChild = do
  isolated <- requireIsolatedRei
  (connection, settings, objective, publication) <- right . Aeson.eitherDecode =<< Lazy.getContents
  tracer <- noopTracer
  manager <- newManager defaultManagerSettings
  let env = AppEnv (defaultConnectionSettings connection) tracer Nothing Nothing
      provider scope = do
        configured <- right (connectionFor settings scope)
        base <- Client.parseBaseUrl (Text.unpack configured.endpoint)
        pure (Rei.mkReiProvider (Client.mkClientEnv manager base) isolated.token scope)
      host = S.TrackerHost objectiveHost settings provider
  disposition <- right =<< run env (Dispatch.dispatch host objective publication)
  assertBool "restart must return retained outcome" (disposition `elem` [Dispatch.Settled, Dispatch.Quarantined])
  exitWith (ExitFailure 91)
