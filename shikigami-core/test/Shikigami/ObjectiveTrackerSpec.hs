{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}

module Shikigami.ObjectiveTrackerSpec (tests) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Shikigami.Objective.Tracker.Command qualified as Command
import Shikigami.Objective.Tracker.Config
import Shikigami.Objective.Tracker.Mapping
import Shikigami.Objective.Tracker.Types
import Shikigami.Objective.Types qualified as O
import Shikigami.Prelude hiding ((.=))
import Shikigami.StateRevision
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "ObjectiveTracker"
    [ testCase "configuration defaults deny passive links all network authority" do
        mayUseConnection defaultTrackerSettings actor scope @?= False
        mayExportConnection defaultTrackerSettings actor scope @?= False
        mayUseConnection settings actor scope @?= True
        mayExportConnection settings actor scope @?= True,
      testCase "connection grant, incarnation and provider revision are separate fences" do
        forM_ [scope & #connectionId .~ key "another", scope & #incarnation .~ key "replacement", scope & #providerRevision .~ key "unreviewed"] \wrong -> mayUseConnection settings actor wrong @?= False
        mayUseConnection settings (O.VerifiedCaller (checked (O.parseCallerId "stranger"))) scope @?= False
        mayExportConnection (settings & #connections .~ [connection & #exportGrants .~ []]) actor scope @?= False,
      testCase "old connection incarnations remain configurable for read-only recovery" do
        let next = connection & #incarnation .~ key "replacement" & #endpoint .~ "https://replacement.test/api/v2"
            both = settings & #connections .~ [connection, next]
        validateTrackerSettings both @?= Right ()
        mayUseConnection both actor scope @?= True
        mayUseConnection both actor (scope & #incarnation .~ next.incarnation) @?= True
        matchesConnection both scope (connectionDigestFor connection) @?= True
        matchesConnection (settings & #connections .~ [connection & #account .~ key "changed-account"]) scope (connectionDigestFor connection) @?= False,
      testCase "configuration bounds work and rejects duplicate connections and invalid actors" do
        validateTrackerSettings settings @?= Right ()
        forM_ [settings & #batchSize .~ 0, settings & #batchSize .~ 101, settings & #pollSeconds .~ 0, settings & #connections .~ [connection, connection], settings & #reconciliationOperators .~ [actor, actor]] \invalid -> assertBool "invalid settings" (isLeft (validateTrackerSettings invalid)),
      testCase "endpoints reject credentials, malformed authorities and remote cleartext" do
        forM_ ["https:///no-host", "https://user:secret@example.test", "https://example.test?token=secret", "https://example.test#secret", "http://example.test:8080", "http://localhost:99999", "http://localhost.evil.test:80", "https://example.test\\@evil.test"] \value -> validEndpoint value @?= False
        forM_ ["https://example.test/api/v2", "http://127.0.0.1:8080/api/v2", "http://[::1]:8080/api/v2"] \value -> validEndpoint value @?= True,
      testCase "configuration and commands reject unknown fields" do
        assertBool "unknown config" (decodeFails @TrackerSettings (Aeson.object ["enabled" .= ("TrackersDisabled" :: Text), "token" .= ("secret" :: Text)]))
        assertBool "unknown command" (decodeFails @Command.Command (Aeson.object ["tag" .= ("ForceResend" :: Text)])),
      testCase "coordinates and content are bounded and protected in diagnostics" do
        forM_ ["", "with whitespace", Text.replicate 257 "x"] \raw -> assertBool "invalid coordinate" (isLeft (parseCoordinate raw :: Either Text TrackerBindingId))
        assertBool "resource private" (not ("SECRET" `Text.isInfixOf` Text.pack (show (key "SECRET" :: ResourceId))))
        assertBool "content private" (not ("SECRET" `Text.isInfixOf` Text.pack (show (RemoteSnapshot (instructions "SECRET") (instructions "SECRET") RemoteOpen))))
        Aeson.eitherDecode (Aeson.encode (observationDigest observation.snapshot)) @?= Right observation.digest,
      testCase "binding initial admission keeps local content and remote baseline separate" do
        let admitted = binding
        admitted.localBase @?= objective.instructions
        admitted.baseline @?= observation
        admitted.localRevision @?= objective.revision
        admitted.state @?= Active,
      testCase "binding requires objective permission independent of connection-use grant" do
        bind settings False [] scope capabilities observation @?= Left TrackerDenied
        bind defaultTrackerSettings True [] scope capabilities observation @?= Left TrackerDenied,
      testCase "unsupported mapping revisions refuse without treating passive links as bindings" do
        assertBool "unsupported mapping" (isLeft (admitBinding settings actor True [] (key "binding") scope (policy & #revision .~ key "unknown") capabilities observation objective)),
      testCase "wrong resource scope and wrong capability revision refuse admission" do
        bind settings True [] (scope & #resourceId .~ key "other") capabilities observation @?= Left TrackerDenied
        bind settings True [] scope (capabilities & #revision .~ key "other") observation @?= Left TrackerDenied,
      testCase "digest and ordered position are verified before admission" do
        bind settings True [] scope capabilities (observation & #digest .~ observationDigest (RemoteSnapshot (instructions "x") (instructions "x") RemoteOpen)) @?= Left TrackerConflict
        assertBool "missing source position" (isLeft (bind settings True [] scope capabilities (observation & #position .~ Nothing))),
      testCase "an active remote resource cannot bind twice and inbound fields have one authority" do
        assertBool "duplicate remote binding" (isLeft (bind settings True [binding & #bindingId .~ key "first"] scope capabilities observation))
        assertBool "duplicate field authority" (isLeft (admitBinding settings actor True [binding & #scope . #resourceId .~ key "other"] (key "second") scope policy capabilities observation objective)),
      testCase "a second outbound-only binding is legal" do
        let outbound = policy & #instructions .~ IgnoreField & #lifecycle .~ IgnoreField
        assertBool "distinct outbound resource" (not (isLeft (admitBinding settings actor True [binding] (key "second") (scope & #resourceId .~ key "other") outbound capabilities (observation & #scope . #resourceId .~ key "other") objective))),
      testCase "identical observations deduplicate and stale positions never decrease the watermark" do
        compareObservation observation observation @?= Right Duplicate
        compareObservation observation (observation & #position .~ Just (revision 0)) @?= Right Older
        stageProposals binding observation @?= Right (Duplicate, []),
      testCase "equal ordered position with different bytes is visible equivocation" do
        compareObservation observation (changed & #position .~ observation.position) @?= Right Equivocation
        stageProposals binding (changed & #position .~ observation.position) @?= Right (Equivocation, []),
      testCase "advancing unchanged fields or display-only edits do not propose imports" do
        stageProposals binding (observation & #position .~ Just (revision 2)) @?= Right (Advance, [])
        let display = observation.snapshot & #display .~ instructions "new display"
        stageProposals binding (observation & #position .~ Just (revision 2) & #snapshot .~ display & #digest .~ observationDigest display) @?= Right (Advance, []),
      testCase "a changed remote instructions value retains the original local base" do
        let (_, proposals) = checked (stageProposals binding changed)
        length proposals @?= 1
        forM_ proposals \proposal -> do
          proposal.localBase @?= objective.instructions
          proposal.localRevision @?= objective.revision
          proposal.observation @?= changed
          proposal.change @?= InstructionsChange (instructions "new remote guidance")
          validateDecision (binding & #latest .~ changed) proposal objective objective.revision @?= Right (),
      testCase "local edit, remote advance, stale expected revision and binding pause refuse a proposal" do
        let proposal = onlyProposal
            current = binding & #latest .~ changed
        forM_ [validateDecision current proposal (objective & #instructions .~ instructions "local edit") objective.revision, validateDecision binding proposal objective objective.revision, validateDecision current proposal objective (revision 99), validateDecision (current & #state .~ Paused) proposal objective objective.revision] \result -> result @?= Left TrackerConflict,
      testCase "remote completion, reopening and deletion are only lifecycle proposals" do
        forM_ [RemoteCompleted, RemoteCancelled, RemoteMissing] \status -> do
          let snapshot = observation.snapshot & #lifecycle .~ status
              next = observation & #position .~ Just (revision 2) & #snapshot .~ snapshot & #digest .~ observationDigest snapshot
          map (.change) (snd (checked (stageProposals binding next))) @?= [LifecycleChange status]
        let terminal = objective & #status .~ O.Completed
            proposal = onlyProposal
        validateDecision (binding & #latest .~ changed) proposal terminal terminal.revision @?= Left TrackerConflict,
      testCase "unordered providers can stage explicit proposals without inventing ordering" do
        let weak = capabilities & #observations .~ UnorderedObservations
            initial = observation & #position .~ Nothing
            next = changed & #position .~ Nothing
            admitted = checked (bind settings True [] scope weak initial)
        validateObservation weak scope initial @?= Right ()
        length (snd (checked (stageProposals admitted next))) @?= 1
        compareObservation observation next @?= Left TrackerConflict,
      testCase "publication payload allowlist excludes protected local prose" do
        let encoded = Text.pack (show (Aeson.encode (summaryFor objective)))
        assertBool "instructions absent" (not ("PRIVATE" `Text.isInfixOf` encoded))
        summaryFor objective @?= ProgressSummary O.Open 0 0 0
    ]

checked :: (Show e) => Either e a -> a
checked = either (error . show) id

key :: Text -> TrackerCoordinate scope
key = checked . parseCoordinate

instructions :: Text -> O.Instructions
instructions = checked . O.parseInstructions

revision :: Integer -> StateRevision scope
revision = checked . parseRevision

actor :: O.AccessPrincipal
actor = O.VerifiedCaller (checked (O.parseCallerId "owner"))

scope :: ResourceScope
scope = ResourceScope (key "connection") (key "incarnation") (key "resource") (key "provider-v1")

capabilities :: Capabilities
capabilities = Capabilities scope.providerRevision OrderedObservations UnconditionalWrites NoIdempotency NoReceiptLookup

policy :: FieldPolicy
policy = FieldPolicy supportedMappingRevision ProposeField ProposeField ProgressSummaries

connection :: Connection
connection = Connection scope.connectionId scope.incarnation scope.providerRevision "https://example.test/api/v2" (key "account") Nothing [actor] [actor]

settings :: TrackerSettings
settings = TrackerSettings TrackersEnabled [connection] 60 20 []

observation :: TrackerObservation
observation = TrackerObservation TrackerV1 scope (Just (revision 1)) (observationDigest snapshot) snapshot
  where
    snapshot = RemoteSnapshot (instructions "remote display") (instructions "initial remote") RemoteOpen

changed :: TrackerObservation
changed = observation & #position .~ Just (revision 2) & #snapshot .~ snapshot & #digest .~ observationDigest snapshot
  where
    snapshot = observation.snapshot & #instructions .~ instructions "new remote guidance"

objective :: O.Objective
objective = O.Objective (checked (O.parseObjectiveId "shikigami_objective_01h455vb4pex5vsknk084sn02q")) actor [O.Member actor [O.Owner]] (checked (O.parseTitle "PRIVATE title")) (checked (O.parseGoal "PRIVATE goal")) (instructions "PRIVATE local instructions") initialRevision initialRevision initialRevision [O.Criterion (checked (O.parseCriterionKey "check")) (checked (O.parseCriterionDescription "integrated result")) O.HumanVerifiable O.JourneyOptional] O.Open [] [] [] [] [] [] [] [] Nothing Nothing

bind :: TrackerSettings -> Bool -> [TrackerBinding] -> ResourceScope -> Capabilities -> TrackerObservation -> Either TrackerError TrackerBinding
bind config allowed existing resource caps initial = admitBinding config actor allowed existing (key "binding") resource policy caps initial objective

binding :: TrackerBinding
binding = checked (bind settings True [] scope capabilities observation)

decodeFails :: forall a. (FromJSON a) => Aeson.Value -> Bool
decodeFails value = case Aeson.fromJSON value :: Aeson.Result a of Aeson.Error _ -> True; _ -> False

onlyProposal :: ImportProposal
onlyProposal = case snd (checked (stageProposals binding changed)) of
  [proposal] -> proposal
  _ -> error "expected one proposal in fixture"
