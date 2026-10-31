-- Database/policy evidence only; marking the fixture profile ready below is a
-- trusted test interpreter and does not qualify native identity provisioning.
module Shikigami.WorkspaceProcessProfileSpec (tests, withProfiles) where

import Control.Concurrent.Async (concurrently)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Transaction (Transaction)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity (CompatibilityIdentity))
import Shikigami.App (AppEnv, runAppIO)
import Shikigami.Execution.AssignmentKey (AssignmentKey, parseAssignmentKey)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Fixture.ExecutionIdentity (fixtureRootId)
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude ((&), (.~))
import Shikigami.StateRevision (StateRevision, parseRevision)
import Shikigami.Workspace.Allocation
import Shikigami.Workspace.Catalog
import Shikigami.Workspace.InstructionLoader (loadWorkspaceAdmission)
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Process (ProcessCommand (..))
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.ProcessProfileStore
import Shikigami.Workspace.Profile
import Shikigami.Workspace.Store qualified as Workspaces
import Shikigami.Workspace.Systemd qualified as Systemd
import Shikigami.Workspace.Types
import Shikigami.WorkspaceStoreSpec qualified as Fixture
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "workspace retained process profiles"
    [ testCase "racing reservations and lost acknowledgement retain one Unix identity and complete policy" $ withProfiles fixture \env policy create -> do
        (binding, admission) <- create "one"
        let reserve = reserveProcessProfileTx binding (bundleDigest admission.instructions) policy pool
        (one, two) <- concurrently (run env reserve) (run env reserve)
        one @?= two
        (profile, state) <- right one
        state @?= ProfileReserved
        profile.userId @?= 62000
        profile.groupId @?= 62000
        profile.policy @?= policy
        run env (readyProcessProfileTx binding profile) >>= (@?= Right ())
        run env reserve >>= (@?= Right (profile, ProfileReady))
        run env (readyProcessProfileTx binding profile) >>= (@?= Right ()),
      testCase "different workspaces receive distinct identities and expiry or freeze cannot recycle them" $ withProfiles fixture \env policy create -> do
        (a, admissionA) <- create "one"
        (b, admissionB) <- create "two"
        (c, admissionC) <- create "three"
        let reserve binding admission = run env (reserveProcessProfileTx binding (bundleDigest admission.instructions) policy pool)
        (one, two) <- concurrently (reserve a admissionA) (reserve b admissionB)
        (profileA, _) <- right one
        (profileB, _) <- right two
        assertBool "distinct identities" (profileA.userId /= profileB.userId)
        run env (Workspaces.freezeWorkspaceTx a a.request.owner a.request.epoch) >>= (@?= Right ())
        reserve a admissionA >>= (@?= Left WorkspaceBindingConflict)
        reserve c admissionC >>= (@?= Left WorkspaceAllocationRefused)
        run env (inspectProcessProfileTx a.workspace) >>= (@?= Just (profileA, ProfileReserved)),
      testCase "changed instructions, rules, identity and binding cannot overwrite a reservation" $ withProfiles fixture \env policy create -> do
        (binding, admission) <- create "one"
        let instructions = bundleDigest admission.instructions
        (profile, _) <- right =<< run env (reserveProcessProfileTx binding instructions policy pool)
        run env (reserveProcessProfileTx binding other policy pool) >>= (@?= Left WorkspaceBindingConflict)
        run env (reserveProcessProfileTx binding instructions (policy & #rules .~ []) pool) >>= (@?= Left InvalidWorkspaceRequest)
        run env (readyProcessProfileTx binding (profile & #userId .~ 62001 & #groupId .~ 62001)) >>= (@?= Left WorkspaceBindingConflict)
        run env (readyProcessProfileTx binding (profile & #bindingDigest .~ other)) >>= (@?= Left WorkspaceBindingConflict)
        run env (inspectProcessProfileTx binding.workspace) >>= (@?= Just (profile, ProfileReserved)),
      testCase "supervisor resolves only ready retained rules with matching instructions and compiled containment properties" $ withProfiles fixture \env policy create -> do
        (binding, admission) <- create "one"
        (profile, _) <- right =<< run env (reserveProcessProfileTx binding (bundleDigest admission.instructions) policy pool)
        assertLeft =<< retainedProcessRule env binding admission "validate"
        run env (readyProcessProfileTx binding profile) >>= (@?= Right ())
        (command, systemd) <- right =<< retainedProcessRule env binding admission "validate"
        command.rule @?= "validate"
        command.arguments @?= ["$HOME", "%n"]
        systemd.userId @?= profile.userId
        Systemd.systemdProfileIdentity systemd >>= (@?= command.profile)
        assertLeft =<< retainedProcessRule env binding admission "unreviewed"
        assertLeft =<< retainedProcessRule env binding (admission & #filePolicy .~ Just nativeFilePolicy) "validate"
        assertLeft =<< retainedProcessRule env binding (admission & #bindingDigest .~ other) "validate"
        assertLeft =<< retainedSystemdProfile (profile & #policy . #propertiesDigest .~ other),
      testCase "invalid pools and a frozen owner refuse before allocating or publishing identity readiness" $ withProfiles fixture \env policy create -> do
        (binding, admission) <- create "one"
        let reserve range = run env (reserveProcessProfileTx binding (bundleDigest admission.instructions) policy range)
        reserve (IdentityRange 0 10) >>= (@?= Left InvalidWorkspaceRequest)
        run env (inspectProcessProfileTx binding.workspace) >>= (@?= Nothing)
        (profile, _) <- right =<< reserve pool
        run env (Workspaces.freezeWorkspaceTx binding binding.request.owner binding.request.epoch) >>= (@?= Right ())
        run env (readyProcessProfileTx binding profile) >>= (@?= Left WorkspaceBindingConflict)
        run env (inspectProcessProfileTx binding.workspace) >>= (@?= Just (profile, ProfileReserved))
    ]

withProfiles :: DatabaseFixture -> (AppEnv -> ProcessPolicy -> (Text.Text -> IO (WorkspaceBinding, WorkspaceAdmission)) -> IO a) -> IO a
withProfiles fixture use = Fixture.withFixture fixture \env source root repository -> do
  properties <- Systemd.systemdPropertiesIdentity
  let image = ProcessImage "/qualified/root" digest "/bin/env" "/bin/deadline" "/qualified/collector"
      rule = CommandRule "validate" "/bin/validate" ["$HOME", "%n"] "" (Map.singleton "HOME" "/scratch") 30 1024
      policy = ProcessPolicy 1 image properties [rule] [""] ["src"]
      base = repositoryBase repository
  catalog <- right (mkWorkspaceCatalog [RepositoryPolicy (repositoryIdentity repository) source [base] base (processPolicyIdentity policy)])
  selected <- right (resolveRepository catalog (repositoryIdentity repository) Nothing)
  let create name = do
        let owner = CompatibilityIdentity (fixtureAgentName "profile-worker")
            request = WorkspaceRequest name Nothing (fixtureRootId ("profile-root-" <> name)) owner owner (fixtureRevision 0)
        (binding, state) <- right =<< run env (Workspaces.reserveWorkspaceTx root request selected)
        allocateWorkspace root binding state >>= (@?= Right ())
        run env (Workspaces.markWorkspaceReadyTx binding) >>= (@?= Right ())
        admission <- right =<< loadWorkspaceAdmission binding (fixtureAssignment ("assignment-" <> name)) 65536
        pure (binding, admission & #filePolicy .~ Just supervisedFilePolicy)
  use env policy create

pool :: IdentityRange
pool = IdentityRange 62000 62001

digest, other :: Text.Text
digest = "sha256:" <> Text.replicate 64 "a"
other = "sha256:" <> Text.replicate 64 "b"

run :: AppEnv -> Transaction a -> IO a
run env action = right =<< runAppIO env (runTransaction action)

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure

assertLeft :: Either a b -> IO ()
assertLeft (Left _) = pure ()
assertLeft _ = assertFailure "unqualified profile accepted"

fixtureRevision :: Integer -> StateRevision scope
fixtureRevision value = either (error . show) id (parseRevision value)

fixtureAssignment :: Text.Text -> AssignmentKey
fixtureAssignment = either (error . show) id . parseAssignmentKey

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName
