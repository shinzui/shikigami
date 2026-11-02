{-# LANGUAGE DataKinds #-}

module Shikigami.ObjectiveTrackerStoreSpec (tests, crashWriter) where

import Control.Concurrent.Async (concurrently)
import Control.Exception (SomeException, throw, try)
import Control.Exception qualified as Exception
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.Either (isLeft, rights)
import Data.Generics.Labels ()
import Data.IORef
import Data.Int (Int64)
import Data.List (nub)
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Effectful (Eff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (allowAllActionAuthorizerForTests)
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Shikigami.Execution.Identity (OperationId)
import Shikigami.Fixture.ExecutionIdentity (fixtureOperationId, fixtureRootId)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Objective.Capability qualified as O
import Shikigami.Objective.Command qualified as OC
import Shikigami.Objective.Store qualified as ObjectiveStore
import Shikigami.Objective.Tracker.Command qualified as C
import Shikigami.Objective.Tracker.Config
import Shikigami.Objective.Tracker.Control qualified as Control
import Shikigami.Objective.Tracker.Control.Types qualified as Control
import Shikigami.Objective.Tracker.Dispatch qualified as Dispatch
import Shikigami.Objective.Tracker.Inspection qualified as Inspection
import Shikigami.Objective.Tracker.Mapping
import Shikigami.Objective.Tracker.Provider qualified as P
import Shikigami.Objective.Tracker.Store qualified as S
import Shikigami.Objective.Tracker.Types
import Shikigami.Objective.Types qualified as OT
import Shikigami.Prelude
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.StateRevision
import Shikigami.WorkerSession.Checkpoint qualified as CP
import Shikigami.WorkerSessionStoreSpec qualified as Fixture
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hClose)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, waitForProcess)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "ObjectiveTrackerStore"
    [ testCase "durable read admission performs no network and restores the original caller after restart" $
        withTracker fixture \env objective original _ -> do
          reads <- newIORef (0 :: Int)
          provider <- right =<< original.providerFor scope
          let selected = provider & #readResource .~ (\requested -> modifyIORef' reads (+ 1) >> provider.readResource requested)
              host = original & #providerFor .~ (\_ -> pure (Right selected))
              operator = checked (OT.parseOperatorId "scheduler")
              scheduler = host & #objective . #settings . #operator .~ Just operator & #objective . #authenticate .~ pure (Right (OT.LocalOperator operator))
              request = Control.RunCommand bindCommand
          (fresh, accepted) <- right =<< run env (Control.enqueue host objective (operation "bind") request)
          fresh @?= True
          accepted.actor @?= actor
          accepted.state @?= Control.Queued
          readIORef reads >>= (@?= 0)
          run env (S.execute host objective (operation "bind") bindCommand) >>= (@?= Left TrackerConflict)
          S.inspectBindings host objective & run env >>= (@?= Right [])
          (replayed, _) <- right =<< run env (Control.enqueue host objective (operation "bind") request)
          replayed @?= False
          run env (S.execute host objective (operation "bind") (C.Pause bindingId initialRevision)) >>= (@?= Left TrackerConflict)
          _ <- right =<< run env (Control.runPending scheduler Nothing)
          record <- right =<< run env (Control.inspect host objective (operation "bind"))
          record.state @?= Control.Finished
          record.failure @?= Nothing
          readIORef reads >>= (@?= 1)
          _ <- right =<< run env (Control.runPending scheduler Nothing)
          _ <- right =<< run env (S.execute host objective (operation "bind") bindCommand)
          readIORef reads >>= (@?= 1),
      testCase "revoked queued callers cannot perform provider reads" $
        withTracker fixture \env objective host _ -> do
          _ <- bind env objective host
          let another = OT.VerifiedCaller (checked (OT.parseCallerId "reviewer"))
              operator = checked (OT.parseOperatorId "scheduler")
              admitted = host & #objective .~ objectiveHost another & #settings . #connections .~ [connection & #useGrants .~ [actor, another]]
              scheduler = admitted & #objective . #settings . #operator .~ Just operator & #objective . #authenticate .~ pure (Right (OT.LocalOperator operator)) & #providerFor .~ (\_ -> fail "revoked request accessed provider")
          _ <- right =<< run env (O.executeCommand ownerHost objective initialRevision (operation "reviewer") (OC.GrantMember another [OT.Coordinator]))
          _ <- right =<< run env (Control.enqueue admitted objective (operation "observe") (Control.Observe bindingId initialRevision))
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 1) (operation "revoke") (OC.RevokeMember another))
          _ <- right =<< run env (Control.runPending scheduler Nothing)
          run env (Control.inspect admitted objective (operation "observe")) >>= (@?= Left TrackerDenied)
          rows <- right =<< run env (S.inspectBindings host objective)
          length rows @?= 1,
      testCase "an unchanged successful poll refreshes last observation time without a new proposal" $
        withTracker fixture \env objective host _ -> do
          _ <- bind env objective host
          before <- right =<< run env (Inspection.binding host objective bindingId)
          _ <- right =<< run env (S.observe host objective bindingId)
          after <- right =<< run env (Inspection.binding host objective bindingId)
          assertBool "successful duplicate read advances local observation time" (after.lastSuccessfulObservation > before.lastSuccessfulObservation)
          after.pendingProposals @?= 0,
      testCase "history keysets traverse beyond the former inspection limit" $
        withTracker fixture \env objective host remote -> do
          _ <- bind env objective host
          forM_ [2 .. 105 :: Integer] \position -> do
            writeIORef remote (initial & #position .~ Just (revision position))
            _ <- right =<< run env (S.observe host objective bindingId)
            pure ()
          let walk after found = do
                page <- right =<< run env (Inspection.history host objective bindingId Control.Observations True after 7)
                if null page then pure found else case reverse page of last : _ -> walk (Just last.identity) (found <> map (.identity) page); _ -> pure found
          identifiers <- walk Nothing []
          length identifiers @?= 105
          length (nub identifiers) @?= 105,
      testCase "explicitly granted authenticated reconcilers retain their caller identity" $
        withTracker fixture \env objective base _ -> do
          (host, _, calls, _) <- deterministic base False
          (intent, _) <- enqueue env objective host
          _ <- right =<< run env (Dispatch.dispatch host objective intent.publicationId)
          (_, receipt) <- single =<< publications env objective host
          attempt <- maybe (fail "missing attempt") pure receipt.attempt
          let granted = host & #settings . #reconciliationOperators .~ [actor]
              command = C.AttestDelivery intent.publicationId attempt.attemptId scope.incarnation (key "remote-receipt") intent.digest receipt.revision (instructions "verified as authenticated operator")
          _ <- right =<< run env (Dispatch.verifyDelivery granted objective intent.publicationId (key "remote-receipt"))
          accepted <- right =<< run env (S.execute granted objective (operation "attest-caller") command)
          accepted.actor @?= actor
          run env (S.execute granted objective (operation "attest-caller") command) >>= (@?= Right accepted)
          readIORef calls >>= (@?= 1),
      testCase "a process exit after commit recovers the original binding and publication without network access" $
        withShikigamiFreshDatabase fixture \connectionString -> do
          env <- environment connectionString
          _ <- right =<< run env Catalog.registerProjectionCatalog
          executable <- getExecutablePath
          (Just input, Nothing, Nothing, child) <- createProcess (proc executable ["--tracker-commit-and-exit", "+RTS", "-N2", "-RTS"]) {std_in = CreatePipe, std_out = NoStream, std_err = Inherit}
          Lazy.hPutStrLn input (Aeson.encode connectionString)
          hClose input
          waitForProcess child >>= (@?= ExitFailure 91)
          fresh <- environment connectionString
          receipt <- right =<< run fresh (O.createObjective ownerHost (operation "create") Nothing request)
          let unavailable = S.TrackerHost ownerHost settings (\_ -> fail "receipt recovery attempted a network client")
          _ <- bind fresh receipt.objectiveId unavailable
          _ <- right =<< run fresh (O.executeCommand ownerHost receipt.objectiveId (revision 0) (operation "progress") (OC.SetBlocked OT.IsBlocked))
          length <$> publications fresh receipt.objectiveId unavailable >>= (@?= 1)
          count fresh "shikigami.objectives" >>= (@?= 1)
          count fresh "shikigami.objective_tracker_commands" >>= (@?= 1)
          count fresh "shikigami.objective_tracker_publications" >>= (@?= 1),
      testCase "explicit binding retains baseline and exact retry without mutating the objective" $
        withTracker fixture \env objective host _ -> do
          before <- get env objective
          receipt <- bind env objective host
          run env (S.execute host objective (operation "bind") bindCommand) >>= (@?= Right receipt)
          get env objective >>= (@?= before)
          bindings <- right =<< run env (S.inspectBindings host objective)
          length bindings @?= 1
          count env "shikigami.objective_tracker_commands" >>= (@?= 1)
          count env "shikigami.objective_tracker_observations" >>= (@?= 1)
          publications env objective host >>= (@?= []),
      testCase "passive external links and connection grants alone never admit bindings" $
        withTracker fixture \env objective host _ -> do
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 0) (operation "link") (OC.LinkExternal (OT.ReiIntention (OT.intentionRef "remote"))))
          run env (S.inspectBindings host objective) >>= (@?= Right [])
          let stranger = OT.VerifiedCaller (checked (OT.parseCallerId "stranger"))
              unauthorized = host & #objective .~ objectiveHost stranger & #settings . #connections .~ [connection & #useGrants .~ [stranger]]
          run env (S.execute unauthorized objective (operation "bind") bindCommand) >>= (@?= Left TrackerDenied)
          run env (S.execute (host & #settings . #connections .~ []) objective (operation "bind") bindCommand) >>= (@?= Left TrackerDenied),
      testCase "real objective command and import decision commit once with checkpoint invalidation" $
        withTracker fixture \env objective host remote -> do
          _ <- bind env objective host
          writeIORef remote changed
          run env (S.observe host objective bindingId) >>= (@?= Right ())
          proposal <- single =<< right =<< run env (S.inspectProposals host objective bindingId)
          let command = C.ApplyProposal bindingId (revision 0) proposal.proposalId (revision 0)
          receipt <- right =<< run env (S.execute host objective (operation "apply") command)
          current <- get env objective
          current.instructions @?= instructions "new remote guidance"
          current.instructionsRevision @?= revision 1
          current.revision @?= revision 1
          run env (S.execute host objective (operation "apply") command) >>= (@?= Right receipt)
          proposals <- right =<< run env (S.inspectProposals host objective bindingId)
          map (.state) proposals @?= [Applied]
          count env "shikigami.objective_receipts" >>= (@?= 2),
      testCase "local divergence refuses, and an explicit rebase retains both decisions" $
        withTracker fixture \env objective host remote -> do
          _ <- bind env objective host
          writeIORef remote changed
          _ <- right =<< run env (S.observe host objective bindingId)
          proposal <- single =<< right =<< run env (S.inspectProposals host objective bindingId)
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 0) (operation "local-edit") (OC.ReviseInstructions (instructions "local edit")))
          run env (S.execute host objective (operation "stale") (C.ApplyProposal bindingId (revision 0) proposal.proposalId (revision 1))) >>= (@?= Left TrackerConflict)
          _ <- right =<< run env (S.execute host objective (operation "rebase") (C.RebaseProposal bindingId (revision 0) proposal.proposalId (revision 1)))
          proposals <- right =<< run env (S.inspectProposals host objective bindingId)
          next <- single (filter ((== AwaitingDecision) . (.state)) proposals)
          next.localBase @?= instructions "local edit"
          length proposals @?= 2
          _ <- right =<< run env (S.execute host objective (operation "new-decision") (C.ApplyProposal bindingId (revision 0) next.proposalId (revision 1)))
          (.instructions) <$> get env objective >>= (@?= instructions "new remote guidance"),
      testCase "duplicate observations deduplicate and newer sources supersede old proposals" $
        withTracker fixture \env objective host remote -> do
          _ <- bind env objective host
          writeIORef remote changed
          _ <- right =<< run env (S.observe host objective bindingId)
          _ <- right =<< run env (S.observe host objective bindingId)
          first <- single =<< right =<< run env (S.inspectProposals host objective bindingId)
          let snapshot = changed.snapshot & #instructions .~ instructions "newer remote"
          writeIORef remote (changed & #position .~ Just (revision 3) & #snapshot .~ snapshot & #digest .~ observationDigest snapshot)
          _ <- right =<< run env (S.observe host objective bindingId)
          proposals <- right =<< run env (S.inspectProposals host objective bindingId)
          length proposals @?= 2
          length (filter ((== Superseded) . (.state)) proposals) @?= 1
          run env (S.execute host objective (operation "old-proposal") (C.ApplyProposal bindingId (revision 0) first.proposalId (revision 0))) >>= (@?= Left TrackerConflict),
      testCase "external completion and deletion do not complete or cancel accepted local work" $
        withTracker fixture \env objective host remote -> do
          _ <- bind env objective host
          let snapshot = initial.snapshot & #lifecycle .~ RemoteCompleted
          writeIORef remote (initial & #position .~ Just (revision 2) & #snapshot .~ snapshot & #digest .~ observationDigest snapshot)
          _ <- right =<< run env (S.observe host objective bindingId)
          proposal <- single =<< right =<< run env (S.inspectProposals host objective bindingId)
          attempted <- run env (S.execute host objective (operation "completion") (C.ApplyProposal bindingId (revision 0) proposal.proposalId (revision 0)))
          assertBool "normal evidence contract required" (isLeft attempted)
          (.status) <$> get env objective >>= (@?= OT.Open),
      testCase "objective progress enqueues one immutable bounded publication in its transaction" $
        withTracker fixture \env objective host _ -> do
          _ <- bind env objective host
          let command = O.executeCommand ownerHost objective (revision 0) (operation "progress") (OC.SetBlocked OT.IsBlocked)
          original <- right =<< run env command
          run env command >>= (@?= Right original)
          (intent, receipt) <- single =<< publications env objective host
          intent.objectiveRevision @?= revision 1
          intent.summary.status @?= OT.Blocked
          receipt.state @?= Pending
          assertBool "private instructions not exported" (not ("PRIVATE" `Text.isInfixOf` Text.pack (Lazy.unpack (Aeson.encode intent))))
          count env "keiro.keiro_outbox" >>= (@?= 1)
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 1) (operation "instructions") (OC.ReviseInstructions (instructions "other private instructions")))
          length <$> publications env objective host >>= (@?= 1),
      testCase "tracker callback failure rolls back objective, receipt and publication together" $
        withTracker fixture \env objective host _ -> do
          _ <- bind env objective host
          before <- get env objective
          outcome <- try @SomeException (run env (O.executeCommandWithTrackerCommit ownerHost actor objective (revision 0) (operation "rollback") (OC.SetBlocked OT.IsBlocked) (\_ _ -> throw (userError "injected transaction failure"))))
          assertBool "fault observed" (isLeft outcome)
          get env objective >>= (@?= before)
          count env "shikigami.objective_receipts" >>= (@?= 1)
          publications env objective host >>= (@?= []),
      testCase "corrupt retained binding condemns objective publication and preserves the retry" $
        withTracker fixture \env objective host _ -> do
          _ <- bind env objective host
          binding <- single =<< right =<< run env (S.inspectBindings host objective)
          replaceBindings env Aeson.Null
          let progress = O.executeCommand ownerHost objective (revision 0) (operation "after-corruption") (OC.SetBlocked OT.IsBlocked)
          run env progress >>= (@?= Left OT.ObjectiveConflict)
          count env "shikigami.objective_receipts" >>= (@?= 1)
          (.revision) <$> get env objective >>= (@?= revision 0)
          replaceBindings env (toJSON binding)
          _ <- right =<< run env progress
          length <$> publications env objective host >>= (@?= 1),
      testCase "two objectives cannot concurrently acquire the same remote resource" $
        withTracker fixture \env objective host _ -> do
          second <- right =<< run env (O.createObjective ownerHost (operation "create-another") Nothing request)
          (first, other) <- concurrently (run env (S.execute host objective (operation "bind-a") bindCommand)) (run env (S.execute host second.objectiveId (operation "bind-b") (C.Bind (key "other-binding") scope policy)))
          length (rights [first, other]) @?= 1
          count env "shikigami.objective_tracker_bindings" >>= (@?= 1),
      testCase "pause and detach retain receipts, and operation-key payload reuse conflicts" $
        withTracker fixture \env objective host _ -> do
          _ <- bind env objective host
          _ <- right =<< run env (S.execute host objective (operation "pause") (C.Pause bindingId (revision 0)))
          run env (S.execute host objective (operation "pause") (C.Resume bindingId (revision 1))) >>= (@?= Left TrackerConflict)
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 0) (operation "progress") (OC.SetBlocked OT.IsBlocked))
          publications env objective host >>= (@?= [])
          _ <- right =<< run env (S.execute host objective (operation "detach") (C.Detach bindingId (revision 1)))
          bindings <- right =<< run env (S.inspectBindings host objective)
          map (.state) bindings @?= [ReconciliationOnly]
          run env (S.execute host objective (operation "bind") bindCommand) >>= (assertBool "original receipt survives detach" . not . isLeft),
      testCase "weak provider quarantines a lost acknowledgement and blocks later sends" $
        withTracker fixture \env objective base _ -> do
          (host, writes, calls, _) <- deterministic base False
          (intent, _) <- enqueue env objective host
          run env (Dispatch.dispatch host objective intent.publicationId) >>= (@?= Right Dispatch.Quarantined)
          run env (Dispatch.dispatch host objective intent.publicationId) >>= (@?= Right Dispatch.Quarantined)
          run env (Dispatch.reconcile host objective intent.publicationId) >>= (@?= Right Dispatch.Quarantined)
          readIORef calls >>= (@?= 1)
          length <$> readIORef writes >>= (@?= 1)
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 1) (operation "next-status") (OC.SetBlocked OT.Unblocked))
          queued <- publications env objective host
          later <- single (filter (\(publication, _) -> publication.objectiveRevision > intent.objectiveRevision) queued)
          run env (Dispatch.dispatch host objective (fst later).publicationId) >>= (@?= Right Dispatch.Deferred)
          readIORef calls >>= (@?= 1),
      testCase "strong provider replays the original request under its retained server key" $
        withTracker fixture \env objective base _ -> do
          (host, writes, calls, _) <- deterministic base True
          (intent, _) <- enqueue env objective host
          run env (Dispatch.dispatch host objective intent.publicationId) >>= (@?= Right Dispatch.Quarantined)
          run env (Dispatch.dispatch host objective intent.publicationId) >>= (@?= Right Dispatch.Settled)
          readIORef calls >>= (@?= 2)
          length <$> readIORef writes >>= (@?= 1)
          (_, receipt) <- single =<< publications env objective host
          receipt.state @?= Delivered
          fmap (.kind) receipt.evidence @?= Just ProviderProved
          count env "shikigami.objective_tracker_attempts" >>= (@?= 1),
      testCase "expired weak claims become Unknown after process loss and never resend" $
        withTracker fixture \env objective base _ -> do
          (normal, writes, calls, _) <- deterministic base False
          selected <- right =<< normal.providerFor scope
          let crash = selected & #publish .~ (\intent attempt -> selected.publish intent attempt >> Exception.throwIO Exception.ThreadKilled)
              host = normal & #providerFor .~ (\_ -> pure (Right crash))
          (intent, _) <- enqueue env objective host
          result <- try @SomeException (run env (Dispatch.dispatch host objective intent.publicationId))
          assertBool "actual process interruption" (isLeft result)
          expireClaims env
          run env (Dispatch.dispatch host objective intent.publicationId) >>= (@?= Right Dispatch.Quarantined)
          readIORef calls >>= (@?= 1)
          length <$> readIORef writes >>= (@?= 1),
      testCase "concurrent executors share a persisted claim before the remote call" $
        withTracker fixture \env objective base _ -> do
          (host, writes, calls, _) <- deterministic base False
          (intent, _) <- enqueue env objective host
          _ <- concurrently (run env (Dispatch.dispatch host objective intent.publicationId)) (run env (Dispatch.dispatch host objective intent.publicationId))
          readIORef calls >>= (@?= 1)
          length <$> readIORef writes >>= (@?= 1),
      testCase "provider proof settles an Unknown receipt without another write" $
        withTracker fixture \env objective base _ -> do
          (host, writes, calls, lookupEnabled) <- deterministic base False
          (intent, _) <- enqueue env objective host
          _ <- right =<< run env (Dispatch.dispatch host objective intent.publicationId)
          writeIORef lookupEnabled True
          run env (Dispatch.reconcile host objective intent.publicationId) >>= (@?= Right Dispatch.Settled)
          (_, receipt) <- single =<< publications env objective host
          receipt.state @?= Delivered
          fmap (.kind) receipt.evidence @?= Just ProviderProved
          readIORef calls >>= (@?= 1)
          length <$> readIORef writes >>= (@?= 1),
      testCase "suppression preserves Unknown and its ordering barrier" $
        withTracker fixture \env objective base _ -> do
          (host, _, calls, _) <- deterministic base False
          (intent, _) <- enqueue env objective host
          _ <- right =<< run env (Dispatch.dispatch host objective intent.publicationId)
          (_, receipt) <- single =<< publications env objective host
          _ <- right =<< run env (S.execute host objective (operation "suppress") (C.SuppressPublication intent.publicationId receipt.revision (instructions "stop future sends")))
          (_, current) <- single =<< publications env objective host
          current.state @?= Unknown
          run env (Dispatch.dispatch host objective intent.publicationId) >>= (@?= Right Dispatch.Quarantined)
          readIORef calls >>= (@?= 1),
      testCase "revocation and binding fences suppress an unsent protected publication" $
        withTracker fixture \env objective base _ -> do
          (host, _, calls, _) <- deterministic base False
          (intent, _) <- enqueue env objective host
          let revoked = host & #settings . #connections .~ [connection & #exportGrants .~ []]
          run env (Dispatch.dispatch revoked objective intent.publicationId) >>= (@?= Right Dispatch.Settled)
          readIORef calls >>= (@?= 0)
          (_, receipt) <- single =<< publications env objective host
          receipt.state @?= Suppressed,
      testCase "an empty lookup cannot prove absence without the declared settled-absence capability" $
        withTracker fixture \env objective base _ -> do
          (host, _, calls, _) <- deterministic base False
          (intent, _) <- enqueue env objective host
          _ <- right =<< run env (Dispatch.dispatch host objective intent.publicationId)
          selected <- right =<< host.providerFor scope
          let lying = host & #providerFor .~ (\_ -> pure (Right (selected & #reconcile .~ (\_ _ -> pure P.ProvedNotApplied))))
          run env (Dispatch.reconcile lying objective intent.publicationId) >>= (@?= Right Dispatch.Quarantined)
          (_, receipt) <- single =<< publications env objective host
          receipt.state @?= Unknown
          readIORef calls >>= (@?= 1),
      testCase "operator attestation requires retained remote verification and current exact receipt revision" $
        withTracker fixture \env objective base _ -> do
          (host, _, calls, _) <- deterministic base False
          (intent, _) <- enqueue env objective host
          _ <- right =<< run env (Dispatch.dispatch host objective intent.publicationId)
          (_, receipt) <- single =<< publications env objective host
          attempt <- maybe (assertFailure "missing attempt" >> fail "unreachable") pure receipt.attempt
          let operator = OT.LocalOperator (checked (OT.parseOperatorId "reconciler"))
              command = C.AttestDelivery intent.publicationId attempt.attemptId scope.incarnation (key "remote-receipt") intent.digest receipt.revision (instructions "verified exact remote action")
          run env (S.execute host objective (operation "attest") command) >>= (@?= Left TrackerDenied)
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 1) (operation "grant-reconciler") (OC.GrantMember operator [OT.Coordinator]))
          let withoutGrant = host & #objective .~ (objectiveHost operator & #settings . #operator .~ Just (checked (OT.parseOperatorId "reconciler")))
              operatorHost = withoutGrant & #settings . #reconciliationOperators .~ [operator]
          run env (S.execute withoutGrant objective (operation "attest") command) >>= (@?= Left TrackerDenied)
          run env (S.execute operatorHost objective (operation "attest") command) >>= (@?= Left TrackerConflict)
          selected <- right =<< operatorHost.providerFor scope
          let wrongProvider = selected & #verifyReceipt .~ (\payload sent remote -> pure (Just (VerifiedDelivery payload.publicationId sent.attemptId (payload.scope & #resourceId .~ key "wrong-resource") remote payload.digest)))
          run env (Dispatch.verifyDelivery (operatorHost & #providerFor .~ (\_ -> pure (Right wrongProvider))) objective intent.publicationId (key "remote-receipt")) >>= (@?= Left TrackerConflict)
          evidence <- right =<< run env (Dispatch.verifyDelivery operatorHost objective intent.publicationId (key "remote-receipt"))
          evidence.digest @?= intent.digest
          forM_
            [ C.AttestDelivery intent.publicationId (key "wrong-attempt") scope.incarnation (key "remote-receipt") intent.digest receipt.revision (instructions "wrong attempt"),
              C.AttestDelivery intent.publicationId attempt.attemptId (key "wrong-incarnation") (key "remote-receipt") intent.digest receipt.revision (instructions "wrong installation"),
              C.AttestDelivery intent.publicationId attempt.attemptId scope.incarnation (key "other-receipt") intent.digest receipt.revision (instructions "wrong receipt"),
              C.AttestDelivery intent.publicationId attempt.attemptId scope.incarnation (key "remote-receipt") (trackerDigest "wrong payload" (toJSON ())) receipt.revision (instructions "wrong digest"),
              C.AttestDelivery intent.publicationId attempt.attemptId scope.incarnation (key "remote-receipt") intent.digest (advanceRevision receipt.revision) (instructions "stale revision")
            ]
            \wrong -> run env (S.execute operatorHost objective (operation "wrong-attestation") wrong) >>= (@?= Left TrackerConflict)
          attested <- right =<< run env (S.execute operatorHost objective (operation "attest") command)
          run env (S.execute operatorHost objective (operation "attest") command) >>= (@?= Right attested)
          (_, delivered) <- single =<< publications env objective host
          delivered.state @?= Delivered
          fmap (.kind) delivered.evidence @?= Just OperatorAttested
          fmap (.actor) delivered.evidence @?= Just (Just operator)
          readIORef calls >>= (@?= 1),
      testCase "a display-only advance keeps an unapplied instructions proposal reviewable" $
        withTracker fixture \env objective host remote -> do
          _ <- bind env objective host
          writeIORef remote changed
          _ <- right =<< run env (S.observe host objective bindingId)
          let snapshot = changed.snapshot & #display .~ instructions "display changed"
          writeIORef remote (changed & #position .~ Just (revision 3) & #snapshot .~ snapshot & #digest .~ observationDigest snapshot)
          _ <- right =<< run env (S.observe host objective bindingId)
          proposals <- right =<< run env (S.inspectProposals host objective bindingId)
          next <- single (filter ((== AwaitingDecision) . (.state)) proposals)
          _ <- right =<< run env (S.execute host objective (operation "apply-current") (C.ApplyProposal bindingId (revision 0) next.proposalId (revision 0)))
          (.instructions) <$> get env objective >>= (@?= instructions "new remote guidance"),
      testCase "an equal-position conflict and lower watermark retain visible diagnostics" $
        withTracker fixture \env objective host remote -> do
          _ <- bind env objective host
          writeIORef remote (changed & #position .~ initial.position)
          _ <- right =<< run env (S.observe host objective bindingId)
          writeIORef remote (initial & #position .~ Just (revision 0))
          _ <- right =<< run env (S.observe host objective bindingId)
          observations <- right =<< run env (S.inspectObservations host objective bindingId)
          assertBool "equivocation visible" ("equivocation" `elem` map fst observations)
          assertBool "older visible" ("older" `elem` map fst observations)
          binding <- single =<< right =<< run env (S.inspectBindings host objective)
          binding.latest @?= initial
          run env (S.inspectProposals host objective bindingId) >>= (@?= Right []),
      testCase "a poll admitted before pause cannot write through the newer binding fence" $
        withTracker fixture \env objective host _ -> do
          _ <- bind env objective host
          selected <- right =<< host.providerFor scope
          let delayed =
                selected
                  & #readResource
                  .~ ( \_ -> do
                         _ <- right =<< run env (S.execute host objective (operation "pause-during-read") (C.Pause bindingId (revision 0)))
                         pure (P.Observed changed)
                     )
              stale = host & #providerFor .~ (\_ -> pure (Right delayed))
          run env (S.observe stale objective bindingId) >>= (@?= Left TrackerDenied)
          run env (S.inspectProposals host objective bindingId) >>= (@?= Right []),
      testCase "expired server keys cannot authorize a second ambiguous send" $
        withTracker fixture \env objective base _ -> do
          (normal, _, calls, _) <- deterministic base True
          now <- getCurrentTime
          selected <- right =<< normal.providerFor scope
          let expired = selected & #capabilities . #idempotency .~ ServerKeysUntil (addUTCTime (-1) now)
              host = normal & #providerFor .~ (\_ -> pure (Right expired))
          (intent, _) <- enqueue env objective host
          _ <- right =<< run env (Dispatch.dispatch host objective intent.publicationId)
          run env (Dispatch.dispatch host objective intent.publicationId) >>= (@?= Right Dispatch.Quarantined)
          run env (Dispatch.reconcile host objective intent.publicationId) >>= (@?= Right Dispatch.Quarantined)
          readIORef calls >>= (@?= 1),
      testCase "disabled tracking preserves accepted command recovery and refuses new imports" $
        withTracker fixture \env objective host remote -> do
          receipt <- bind env objective host
          let disabled = host & #settings . #enabled .~ TrackersDisabled
          run env (S.execute disabled objective (operation "bind") bindCommand) >>= (@?= Right receipt)
          run env (S.execute disabled objective (operation "new-bind") (C.Bind (key "other") scope policy)) >>= (@?= Left TrackerDenied)
          writeIORef remote changed
          run env (S.observe disabled objective bindingId) >>= (@?= Left TrackerDenied),
      testCase "an unresolved detached binding cannot be replaced by another binding" $
        withTracker fixture \env objective base _ -> do
          (host, _, calls, _) <- deterministic base False
          (intent, _) <- enqueue env objective host
          _ <- right =<< run env (Dispatch.dispatch host objective intent.publicationId)
          _ <- right =<< run env (S.execute host objective (operation "detach") (C.Detach bindingId (revision 0)))
          run env (S.execute host objective (operation "replace") (C.Bind (key "replacement") scope policy)) >>= (@?= Left TrackerConflict)
          run env (Dispatch.dispatch host objective intent.publicationId) >>= (@?= Right Dispatch.Quarantined)
          readIORef calls >>= (@?= 1),
      testCase "an Unknown publication blocks only its own binding" $
        withTracker fixture \env objective base _ -> do
          (normal, writes, calls, _) <- deterministic base False
          selected <- right =<< normal.providerFor scope
          let provider = selected & #readResource .~ (\resource -> pure (P.Observed (initial & #scope .~ resource)))
              host = normal & #providerFor .~ (\_ -> pure (Right provider))
              secondBinding = key "second-binding"
              secondScope = scope & #resourceId .~ key "another-resource"
              outbound = policy & #instructions .~ IgnoreField & #lifecycle .~ IgnoreField
          _ <- bind env objective host
          _ <- right =<< run env (S.execute host objective (operation "bind-second") (C.Bind secondBinding secondScope outbound))
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 0) (operation "progress") (OC.SetBlocked OT.IsBlocked))
          (first, _) <- single =<< publications env objective host
          (second, _) <- single =<< right =<< run env (S.inspectPublications host objective secondBinding)
          run env (Dispatch.dispatch host objective first.publicationId) >>= (@?= Right Dispatch.Quarantined)
          run env (Dispatch.dispatch host objective second.publicationId) >>= (@?= Right Dispatch.Settled)
          readIORef calls >>= (@?= 2)
          length <$> readIORef writes >>= (@?= 2),
      testCase "a definitely-not-sent result admits another actual attempt" $
        withTracker fixture \env objective base _ -> do
          (normal, writes, calls, _) <- deterministic base False
          selected <- right =<< normal.providerFor scope
          first <- newIORef True
          let provider =
                selected
                  & #publish
                  .~ ( \intent attempt -> do
                         unsent <- atomicModifyIORef' first (\old -> (False, old))
                         if unsent then pure P.DefinitelyNotSent else selected.publish intent attempt
                     )
              host = normal & #providerFor .~ (\_ -> pure (Right provider))
          (intent, _) <- enqueue env objective host
          run env (Dispatch.dispatch host objective intent.publicationId) >>= (@?= Right Dispatch.Deferred)
          run env (Dispatch.dispatch host objective intent.publicationId) >>= (@?= Right Dispatch.Quarantined)
          readIORef calls >>= (@?= 1)
          length <$> readIORef writes >>= (@?= 1)
          count env "shikigami.objective_tracker_attempts" >>= (@?= 2),
      testCase "proved settled non-application permits a new attempt under the logical publication" $
        withTracker fixture \env objective base _ -> do
          selected <- right =<< base.providerFor scope
          first <- newIORef True
          calls <- newIORef (0 :: Int)
          let provider =
                selected
                  & #capabilities
                  . #receiptLookup
                  .~ LookupAppliedAndSettledAbsence
                  & #publish
                  .~ ( \_ _ -> do
                         modifyIORef' calls (+ 1)
                         unknown <- atomicModifyIORef' first (\old -> (False, old))
                         pure (if unknown then P.OutcomeUnknown else P.Acknowledged (key "settled-receipt"))
                     )
                  & #reconcile
                  .~ (\_ _ -> pure P.ProvedNotApplied)
              host = base & #providerFor .~ (\_ -> pure (Right provider))
          (intent, _) <- enqueue env objective host
          run env (Dispatch.dispatch host objective intent.publicationId) >>= (@?= Right Dispatch.Quarantined)
          run env (Dispatch.reconcile host objective intent.publicationId) >>= (@?= Right Dispatch.Deferred)
          run env (Dispatch.dispatch host objective intent.publicationId) >>= (@?= Right Dispatch.Settled)
          readIORef calls >>= (@?= 2)
          count env "shikigami.objective_tracker_attempts" >>= (@?= 2),
      testCase "imported instructions invalidate the real worker checkpoint version" $
        withTracker fixture \env objective host remote -> do
          now <- getCurrentTime
          let assignmentId = checked (OT.parseObjectiveAssignmentId "worker")
              draft = OT.AssignmentDraft assignmentId (instructions "worker instructions") [] (compatibilityIdentity (checked (mkAgentName "worker"))) OT.Pending Nothing (Just (fixtureRootId "session-root")) (Just (addUTCTime 3600 now))
              reference = ObjectiveStore.referenceFor objective assignmentId
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 0) (operation "assign") (OC.SetAssignments [draft]))
          before <- right =<< run env (O.readCheckpointVersion ownerHost reference)
          _ <- bind env objective host
          writeIORef remote changed
          _ <- right =<< run env (S.observe host objective bindingId)
          proposal <- single =<< right =<< run env (S.inspectProposals host objective bindingId)
          _ <- right =<< run env (S.execute host objective (operation "import") (C.ApplyProposal bindingId (revision 0) proposal.proposalId (revision 1)))
          after <- right =<< run env (O.readCheckpointVersion ownerHost reference)
          after.assignmentRevision @?= advanceRevision before.assignmentRevision,
      testCase "revocation denies an identical successful import retry before receipt lookup" $
        withTracker fixture \env objective host remote -> do
          let delegate = OT.VerifiedCaller (checked (OT.parseCallerId "delegate"))
              delegated = host & #objective .~ objectiveHost delegate & #settings . #connections .~ [connection & #useGrants .~ [actor, delegate]]
          _ <- bind env objective host
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 0) (operation "grant") (OC.GrantMember delegate [OT.Coordinator]))
          writeIORef remote changed
          _ <- right =<< run env (S.observe delegated objective bindingId)
          proposal <- single =<< right =<< run env (S.inspectProposals delegated objective bindingId)
          let command = C.ApplyProposal bindingId (revision 0) proposal.proposalId (revision 1)
          _ <- right =<< run env (S.execute delegated objective (operation "import") command)
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 2) (operation "revoke") (OC.RevokeMember delegate))
          run env (S.execute delegated objective (operation "import") command) >>= (@?= Left TrackerDenied),
      testCase "a late exact acknowledgement settles its expired claim without a second send" $
        withTracker fixture \env objective base _ -> do
          selected <- right =<< base.providerFor scope
          calls <- newIORef (0 :: Int)
          let provider =
                selected
                  & #publish
                  .~ ( \intent _ -> do
                         modifyIORef' calls (+ 1)
                         expireClaims env
                         run env (Dispatch.dispatch host objective intent.publicationId) >>= (@?= Right Dispatch.Quarantined)
                         pure (P.Acknowledged (key "late-receipt"))
                     )
              host = base & #providerFor .~ (\_ -> pure (Right provider))
          (intent, _) <- enqueue env objective host
          run env (Dispatch.dispatch host objective intent.publicationId) >>= (@?= Right Dispatch.Settled)
          readIORef calls >>= (@?= 1)
          (_, receipt) <- single =<< publications env objective host
          receipt.state @?= Delivered,
      testCase "changing an endpoint or account without a new incarnation cannot redirect retained work" $
        withTracker fixture \env objective base _ -> do
          (host, _, calls, _) <- deterministic base False
          (intent, _) <- enqueue env objective host
          forM_ [connection & #endpoint .~ "https://replacement.test/api/v2", connection & #account .~ key "replacement-account"] \replacement -> do
            let changedHost = host & #settings . #connections .~ [replacement]
            run env (Dispatch.dispatch changedHost objective intent.publicationId) >>= (@?= Left TrackerConflict)
            run env (S.observe changedHost objective bindingId) >>= (@?= Left TrackerDenied)
          readIORef calls >>= (@?= 0)
          (_, receipt) <- single =<< publications env objective host
          receipt.state @?= Pending
    ]

enqueue :: AppEnv -> OT.ObjectiveId -> S.TrackerHost -> IO (PublicationIntent, PublicationReceipt)
enqueue env objective host = do
  _ <- bind env objective host
  _ <- right =<< run env (O.executeCommand ownerHost objective (revision 0) (operation "progress") (OC.SetBlocked OT.IsBlocked))
  single =<< publications env objective host

-- Both deterministic providers execute the production Store/Dispatch path.
-- The strong provider deduplicates server-side; the weak one appends per call.
deterministic :: S.TrackerHost -> Bool -> IO (S.TrackerHost, IORef [PublicationIntent], IORef Int, IORef Bool)
deterministic base strong = do
  writes <- newIORef []
  calls <- newIORef 0
  loseAcknowledgement <- newIORef True
  lookupEnabled <- newIORef False
  now <- getCurrentTime
  original <- right =<< base.providerFor scope
  let provider =
        original
          & #capabilities
          . #idempotency
          .~ (if strong then ServerKeysUntil (addUTCTime 3600 now) else NoIdempotency)
          & #publish
          .~ ( \intent _ -> do
                 modifyIORef' calls (+ 1)
                 modifyIORef' writes (\retained -> if strong && any ((== intent.publicationId) . (.publicationId)) retained then retained else retained <> [intent])
                 lost <- atomicModifyIORef' loseAcknowledgement (\first -> (False, first))
                 pure (if lost then P.OutcomeUnknown else P.Acknowledged (key "remote-receipt"))
             )
          & #reconcile
          .~ ( \intent attempt -> do
                 available <- readIORef lookupEnabled
                 remote <- readIORef writes
                 pure (if available && intent `elem` remote then P.ProvedApplied (VerifiedDelivery intent.publicationId attempt.attemptId intent.scope (key "remote-receipt") intent.digest) else P.StillUnknown)
             )
          & #verifyReceipt
          .~ ( \intent attempt remote -> do
                 retained <- readIORef writes
                 pure (if intent `elem` retained && remote == key "remote-receipt" then Just (VerifiedDelivery intent.publicationId attempt.attemptId intent.scope remote intent.digest) else Nothing)
             )
  pure (base & #providerFor .~ (\_ -> pure (Right provider)), writes, calls, lookupEnabled)

expireClaims :: AppEnv -> IO ()
expireClaims env = run env (runTransaction (Tx.sql "UPDATE shikigami.objective_tracker_publications SET receipt=jsonb_set(receipt,'{claim,expiresAt}',to_jsonb('2000-01-01T00:00:00Z'::text),false) WHERE receipt_state='Attempting'"))

environment :: Text -> IO AppEnv
environment connectionString = do
  tracer <- noopTracer
  pure (AppEnv (defaultConnectionSettings connectionString) tracer Nothing Nothing)

crashWriter :: IO ()
crashWriter = do
  connectionString <- right . Aeson.eitherDecode =<< Lazy.getContents
  env <- environment connectionString
  receipt <- right =<< run env (O.createObjective ownerHost (operation "create") Nothing request)
  remote <- newIORef initial
  let provider = P.Provider capabilities (\_ -> P.Observed <$> readIORef remote) (\_ _ -> pure P.OutcomeUnknown) (\_ _ -> pure P.StillUnknown) (\_ _ _ -> pure Nothing)
      host = S.TrackerHost ownerHost settings (\_ -> pure (Right provider))
  _ <- enqueue env receipt.objectiveId host
  exitWith (ExitFailure 91)

withTracker :: DatabaseFixture -> (AppEnv -> OT.ObjectiveId -> S.TrackerHost -> IORef TrackerObservation -> IO a) -> IO a
withTracker fixture callback = Fixture.withFixture fixture \env _ _ -> do
  created <- right =<< run env (O.createObjective ownerHost (operation "create") Nothing request)
  remote <- newIORef initial
  let selected = P.Provider capabilities (\_ -> P.Observed <$> readIORef remote) (\_ _ -> pure P.OutcomeUnknown) (\_ _ -> pure P.StillUnknown) (\_ _ _ -> pure Nothing)
      host = S.TrackerHost ownerHost settings (\_ -> pure (Right selected))
  callback env created.objectiveId host remote

request :: OT.CreateRequest
request = OT.CreateRequest (checked (OT.parseTitle "PRIVATE title")) (checked (OT.parseGoal "PRIVATE goal")) (instructions "PRIVATE local instructions") [OT.Criterion (checked (OT.parseCriterionKey "review")) (checked (OT.parseCriterionDescription "integrated acceptance")) OT.HumanVerifiable OT.JourneyOptional] []

actor :: OT.AccessPrincipal
actor = OT.VerifiedCaller (checked (OT.parseCallerId "owner"))

objectiveHost :: OT.AccessPrincipal -> O.ObjectiveHost
objectiveHost principal = O.ObjectiveHost (OT.defaultObjectiveSettings & #enabled .~ OT.ObjectivesEnabled) (pure (Right principal)) allowAllActionAuthorizerForTests (\_ _ -> pure (Right ())) (\_ _ -> pure (Right ())) (\_ -> pure (Left OT.ObjectiveInvalidEvidence))

ownerHost :: O.ObjectiveHost
ownerHost = objectiveHost actor

get :: AppEnv -> OT.ObjectiveId -> IO OT.Objective
get env objective = right =<< run env (O.readObjective ownerHost objective)

bind :: AppEnv -> OT.ObjectiveId -> S.TrackerHost -> IO CommandReceipt
bind env objective host = right =<< run env (S.execute host objective (operation "bind") bindCommand)

bindCommand :: C.Command
bindCommand = C.Bind bindingId scope policy

bindingId :: TrackerBindingId
bindingId = key "binding"

scope :: ResourceScope
scope = ResourceScope (key "connection") (key "installation") (key "remote") (key "weak-v1")

policy :: FieldPolicy
policy = FieldPolicy supportedMappingRevision ProposeField ProposeField ProgressSummaries

capabilities :: Capabilities
capabilities = Capabilities scope.providerRevision OrderedObservations UnconditionalWrites NoIdempotency LookupApplied

connection :: Connection
connection = Connection scope.connectionId scope.incarnation scope.providerRevision "https://example.test/api/v2" (key "account") Nothing [actor] [actor]

settings :: TrackerSettings
settings = TrackerSettings TrackersEnabled [connection] 60 20 []

initial :: TrackerObservation
initial = TrackerObservation TrackerV1 scope (Just (revision 1)) (observationDigest snapshot) snapshot
  where
    snapshot = RemoteSnapshot (instructions "display") (instructions "initial remote guidance") RemoteOpen

changed :: TrackerObservation
changed = initial & #position .~ Just (revision 2) & #snapshot .~ snapshot & #digest .~ observationDigest snapshot
  where
    snapshot = initial.snapshot & #instructions .~ instructions "new remote guidance"

instructions :: Text -> OT.Instructions
instructions = checked . OT.parseInstructions

key :: Text -> TrackerCoordinate scope
key = checked . parseCoordinate

revision :: Integer -> StateRevision scope
revision = checked . parseRevision

operation :: Text -> OperationId
operation = fixtureOperationId

checked :: (Show e) => Either e a -> a
checked = either (error . show) id

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure

single :: [a] -> IO a
single [value] = pure value
single values = assertFailure ("expected one value, got " <> show (length values)) >> fail "unreachable"

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = right =<< runAppIO env action

publications :: AppEnv -> OT.ObjectiveId -> S.TrackerHost -> IO [(PublicationIntent, PublicationReceipt)]
publications env objective host = right =<< run env (S.inspectPublications host objective bindingId)

count :: AppEnv -> Text -> IO Int64
count env table = run env (runTransaction (Tx.statement () (preparable ("SELECT count(*) FROM " <> table) E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))))

replaceBindings :: AppEnv -> Aeson.Value -> IO ()
replaceBindings env value = run env (runTransaction (Tx.statement value (preparable "UPDATE shikigami.objective_tracker_bindings SET state=$1" (E.param (E.nonNullable E.jsonb)) D.noResult)))
