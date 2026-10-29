module Shikigami.WorkspaceActionProofSpec (tests) where

import Auth.Biscuit (toPublic)
import Data.Aeson (toJSON)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8)
import Data.Time (addUTCTime)
import En.Biscuit.Grant qualified as Grant
import En.Biscuit.Keys (parseSigningKeyText, singleKey)
import En.Biscuit.Mint (MintConfig (..), MintedGrant (..), mintObjectGrantWithExpiry)
import En.Check (CheckDecision (Allowed))
import En.Revision qualified as En
import En.Schema (ObjectType (..), RelationName (..))
import En.Tuple (ObjectRef (..), Subject (SubjectId))
import Kikan.En.Action qualified as Kikan
import Kikan.En.Client (newActionProofVerifier, verifyIssuedAction)
import Shikigami.Agent.Principal (AgentIdentity (..), mkAgentPrincipal)
import Shikigami.Execution.Identity
import Shikigami.Execution.Runner
import Shikigami.Execution.Transcript (ExecutionId (..))
import Shikigami.Prelude ((&), (.~))
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Process
import Shikigami.Workspace.Provider
import Shikigami.Workspace.Reference
import Shikigami.Workspace.Types
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "workspace exact action proofs"
    [ testCase "real producer and verifier bind every workspace and dispatch coordinate" $ do
        (keyId, secret) <- right (parseSigningKeyText "1:a2c4ead323536b925f3488ee83e0888b79c2761405ca7c0c9a018c7c1905eecc")
        actor <- right (mkAgentPrincipal "agent_01h000000000000000triage")
        principal <- right (Kikan.mkAgentPrincipal "agent_01h000000000000000triage")
        requestId <- right (Kikan.mkRequestId "workspace-proof")
        schema <- right (Kikan.mkActionSchemaHash "schema-workspace-fixture")
        let owner = VerifiedIdentity actor
            request = WorkspaceRequest "run" Nothing (ExecutionRootId "root") owner owner 0
            binding = WorkspaceBinding request (WorkspaceRef "shikigami.workspace/1" "resource") "mori://fixture/repo" (Text.replicate 40 "a") "policy-1" "/private/workspaces" "/operator/source"
            logical = OperationContext (ExecutionId "execution") (OperationId "operation") "operation" "fingerprint" "scope"
            dispatch = DispatchContext logical (AttemptId "attempt") "claim-owner" 1
            now = read "2026-10-29 12:00:00 UTC"
            expiry = addUTCTime 30 now
            verifier = newActionProofVerifier (singleKey keyId (toPublic secret)) (Set.singleton schema) (const (pure False))
            admissionFor b = do
              bundle <- right (mkInstructionBundle 65536 b.repository b.base [("AGENTS.md", "fixture policy")])
              pure (WorkspaceAdmission b.workspace (workspaceBindingDigest b) b.request.runId "assignment" b.request.rootId b.request.owner b.request.epoch bundle (Just nativeFilePolicy))
        admission <- admissionFor binding
        workspaceFileAction binding (admission & #filePolicy .~ Nothing) dispatch "replace" "src/file" "device:parent" "input-hash" @?= Left FileEffectRefused
        workspaceFileAction binding (admission & #filePolicy .~ Just "unqualified-profile") dispatch "replace" "src/file" "device:parent" "input-hash" @?= Left FileEffectRefused
        exact <- right (workspaceFileAction binding admission dispatch "replace" "src/file" "device:parent" "input-hash")
        let actionRequest = Kikan.AuthorizeActionRequest principal exact requestId
            grant = Grant.EnGrant (SubjectId (ObjectRef (ObjectType "agent") (Kikan.agentPrincipalText principal))) (RelationName (Kikan.actionOperation exact)) (ObjectRef (ObjectType (Kikan.actionObjectType exact)) (Kikan.actionObjectId exact)) (En.ConsistencyToken "snapshot-1") (En.SchemaHash "schema-workspace-fixture") expiry (Grant.Audience "shikigami") (Just (Grant.RequestId "workspace-proof")) Nothing
        minted <- right =<< mintObjectGrantWithExpiry (MintConfig secret keyId 30 (pure now)) expiry Allowed grant
        proof <- right (Kikan.mkDecisionProof (decodeUtf8 minted.token))
        checkedAt <- right (Kikan.mkConsistencyToken "snapshot-1")
        let issued = Kikan.IssuedActionProof proof minted.expiresAt [] checkedAt
        _ <- right =<< verifyIssuedAction verifier now actionRequest issued
        let changedBindings = [binding & #repository .~ "mori://fixture/other", binding & #base .~ Text.replicate 40 "b", binding & #policyRevision .~ "policy-2", binding & #workspace . #resource .~ "other-resource", binding & #request . #rootId .~ ExecutionRootId "other-root", binding & #request . #epoch .~ 1, binding & #request . #runId .~ "other-run"]
        bindingActions <- mapM (\b -> admissionFor b >>= \a -> right (workspaceFileAction b a dispatch "replace" "src/file" "device:parent" "input-hash")) changedBindings
        changedPolicy <- right (mkInstructionBundle 65536 binding.repository binding.base [("AGENTS.md", "changed policy")])
        coordinateActions <-
          mapM
            right
            [ workspaceFileAction binding (admission & #instructions .~ changedPolicy) dispatch "replace" "src/file" "device:parent" "input-hash",
              workspaceFileAction binding (admission & #assignmentId .~ "other-assignment") dispatch "replace" "src/file" "device:parent" "input-hash",
              workspaceFileAction binding admission (dispatch & #attemptId .~ AttemptId "other-attempt") "replace" "src/file" "device:parent" "input-hash",
              workspaceFileAction binding admission (dispatch & #owner .~ "other-claim") "replace" "src/file" "device:parent" "input-hash",
              workspaceFileAction binding admission (dispatch & #generation .~ 2) "replace" "src/file" "device:parent" "input-hash",
              workspaceFileAction binding admission (dispatch & #operation . #operationId .~ OperationId "other-operation") "replace" "src/file" "device:parent" "input-hash",
              workspaceFileAction binding admission (dispatch & #operation . #fingerprint .~ "other-fingerprint") "replace" "src/file" "device:parent" "input-hash",
              workspaceFileAction binding admission (dispatch & #operation . #scopeDigest .~ "other-scope") "replace" "src/file" "device:parent" "input-hash",
              workspaceFileAction binding admission dispatch "read" "src/file" "device:parent" "input-hash",
              workspaceFileAction binding admission dispatch "replace" "src/other" "device:parent" "input-hash",
              workspaceFileAction binding admission dispatch "replace" "src/file" "device:other-parent" "input-hash",
              workspaceFileAction binding admission dispatch "replace" "src/file" "device:parent" "other-input"
            ]
        mapM_
          ( \action -> do
              result <- verifyIssuedAction verifier now (actionRequest & #action .~ action) issued
              assertBool "changed coordinate cannot reuse proof" (case result of Left Kikan.ProofWrongResource -> True; _ -> False)
          )
          (bindingActions <> coordinateActions)
        result <- verifyIssuedAction verifier expiry actionRequest issued
        assertBool "expiry enforced" (case result of Left Kikan.ProofExpired -> True; _ -> False)
        assertBool "proof bytes excluded from public contracts" (not (Kikan.decisionProofText proof `Text.isInfixOf` Text.pack (show (toJSON (binding, admission)))))
        let processAdmission = admission & #filePolicy .~ Just supervisedFilePolicy
            command = ProcessCommand "validate" ("sha256:" <> Text.replicate 64 "a") "/bin/validate" [] "src" (Map.singleton "HOME" "/scratch") 30 1024
            boot = "11111111-1111-4111-8111-111111111111"
            recordFor b a d c =
              let fingerprint = processFingerprint b (bundleDigest a.instructions) d.operation c
               in ProcessRecord d.operation.operationId d.attemptId d.owner d.generation (workspaceBindingDigest b) (bundleDigest a.instructions) fingerprint c expiry (processUnit d.operation.operationId fingerprint) Nothing Nothing ProcessReserved Nothing
            record = recordFor binding processAdmission dispatch command
        workspaceProcessAction binding admission dispatch record boot "device:parent" @?= Left FileEffectRefused
        workspaceFileAction binding processAdmission dispatch "replace" "src/file" "device:parent" "input-hash" @?= Left FileEffectRefused
        processAction <- right (workspaceProcessAction binding processAdmission dispatch record boot "device:parent")
        let processRequest = Kikan.AuthorizeActionRequest principal processAction requestId
            processGrant = Grant.EnGrant (SubjectId (ObjectRef (ObjectType "agent") (Kikan.agentPrincipalText principal))) (RelationName (Kikan.actionOperation processAction)) (ObjectRef (ObjectType (Kikan.actionObjectType processAction)) (Kikan.actionObjectId processAction)) (En.ConsistencyToken "snapshot-1") (En.SchemaHash "schema-workspace-fixture") expiry (Grant.Audience "shikigami") (Just (Grant.RequestId "workspace-proof")) Nothing
        processMinted <- right =<< mintObjectGrantWithExpiry (MintConfig secret keyId 30 (pure now)) expiry Allowed processGrant
        processProof <- right (Kikan.mkDecisionProof (decodeUtf8 processMinted.token))
        let processIssued = Kikan.IssuedActionProof processProof processMinted.expiresAt [] checkedAt
        _ <- right =<< verifyIssuedAction verifier now processRequest processIssued
        workspaceProcessAction binding processAdmission dispatch (record & #phase .~ ProcessLaunchRequested & #bootId .~ Just boot) boot "device:parent" @?= Right processAction
        let alteredCommands =
              [ command & #rule .~ "other-rule",
                command & #profile .~ ("sha256:" <> Text.replicate 64 "b"),
                command & #executable .~ "/bin/other",
                command & #arguments .~ ["different"],
                command & #directory .~ "other",
                command & #environment .~ Map.singleton "HOME" "/workspace",
                command & #timeoutSeconds .~ 29,
                command & #outputBytes .~ 512
              ]
            alteredDispatches =
              [ dispatch & #attemptId .~ AttemptId "other-attempt",
                dispatch & #owner .~ "other-claim",
                dispatch & #generation .~ 2,
                dispatch & #operation . #operationId .~ OperationId "other-operation",
                dispatch & #operation . #fingerprint .~ "other-fingerprint",
                dispatch & #operation . #scopeDigest .~ "other-scope"
              ]
        processActions <-
          mapM
            right
            ( [workspaceProcessAction binding processAdmission dispatch (recordFor binding processAdmission dispatch changed) boot "device:parent" | changed <- alteredCommands]
                <> [workspaceProcessAction binding processAdmission changed (recordFor binding processAdmission changed command) boot "device:parent" | changed <- alteredDispatches]
                <> [ workspaceProcessAction binding processAdmission dispatch (record & #deadline .~ addUTCTime 1 expiry) boot "device:parent",
                     workspaceProcessAction binding processAdmission dispatch record "22222222-2222-4222-8222-222222222222" "device:parent",
                     workspaceProcessAction binding processAdmission dispatch record boot "device:other-parent",
                     workspaceProcessAction binding (processAdmission & #assignmentId .~ "other-assignment") dispatch record boot "device:parent"
                   ]
            )
        processBindingActions <-
          mapM
            ( \changed -> do
                changedAdmission <- (\a -> a & #filePolicy .~ Just supervisedFilePolicy) <$> admissionFor changed
                right (workspaceProcessAction changed changedAdmission dispatch (recordFor changed changedAdmission dispatch command) boot "device:parent")
            )
            changedBindings
        mapM_
          ( \action -> do
              rejected <- verifyIssuedAction verifier now (processRequest & #action .~ action) processIssued
              assertBool "process proof binds command, profile, original attempt, boot, cwd and deadline" (case rejected of Left Kikan.ProofWrongResource -> True; _ -> False)
          )
          (processBindingActions <> processActions)
        mapM_
          (\invalid -> workspaceProcessAction binding processAdmission dispatch invalid boot "device:parent" @?= Left FileEffectRefused)
          [ record & #attemptId .~ AttemptId "unmatched-attempt",
            record & #generation .~ 2,
            record & #fingerprint .~ "mismatched",
            record & #phase .~ ProcessRunning,
            record & #bootId .~ Just "22222222-2222-4222-8222-222222222222",
            record & #invocationId .~ Just boot
          ]
    ]

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure
