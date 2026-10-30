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
import Shikigami.Execution.Transcript (ExecutionId (..), NextWork (..), PayloadRef (..))
import Shikigami.Prelude ((&), (.~))
import Shikigami.Workspace.GitTypes qualified as Git
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessPolicy
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
               in ProcessRecord d.operation.operationId d.attemptId d.owner d.generation (workspaceBindingDigest b) (bundleDigest a.instructions) fingerprint c expiry (processUnit d.operation.operationId fingerprint) Nothing Nothing ProcessReserved Nothing (Just (ProcessRouting 1 d.operation.executionId b.request.owner ("sha256:" <> Text.replicate 64 "a") NeedModel))
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
                     workspaceProcessAction binding (processAdmission & #assignmentId .~ "other-assignment") dispatch record boot "device:parent",
                     workspaceProcessAction binding processAdmission dispatch (record & #routing .~ Just (ProcessRouting 1 logical.executionId owner ("sha256:" <> Text.replicate 64 "b") NeedModel)) boot "device:parent",
                     workspaceProcessAction binding processAdmission dispatch (record & #routing .~ Just (ProcessRouting 1 logical.executionId owner ("sha256:" <> Text.replicate 64 "a") (NeedTool (PayloadRef "response" ("sha256:" <> Text.replicate 64 "a") 1) 1))) boot "device:parent"
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
            record & #invocationId .~ Just boot,
            record & #routing .~ Nothing
          ]
        let policy = ProcessPolicy 1 (ProcessImage "/qualified/root" command.profile "/bin/env" "/bin/deadline" "/qualified/collector") command.profile [CommandRule "validate" "/bin/validate" [] "" Map.empty 30 1024] [""] ["src"]
            provisionBinding = binding & #policyRevision .~ processPolicyIdentity policy
        provisionAdmission <- (\a -> a & #filePolicy .~ Just supervisedFilePolicy) <$> admissionFor provisionBinding
        let profileFor b a selected uid = ProcessProfile (workspaceBindingDigest b) (bundleDigest a.instructions) selected uid uid
            profile = profileFor provisionBinding provisionAdmission policy 62001
        fileAction <- right (workspaceSupervisedFileAction profile provisionBinding provisionAdmission dispatch "replace" "src/file" "device:parent" "input-hash")
        let fileRequest = Kikan.AuthorizeActionRequest principal fileAction requestId
            fileGrant = Grant.EnGrant (SubjectId (ObjectRef (ObjectType "agent") (Kikan.agentPrincipalText principal))) (RelationName (Kikan.actionOperation fileAction)) (ObjectRef (ObjectType (Kikan.actionObjectType fileAction)) (Kikan.actionObjectId fileAction)) (En.ConsistencyToken "snapshot-1") (En.SchemaHash "schema-workspace-fixture") expiry (Grant.Audience "shikigami") (Just (Grant.RequestId "workspace-proof")) Nothing
        fileMinted <- right =<< mintObjectGrantWithExpiry (MintConfig secret keyId 30 (pure now)) expiry Allowed fileGrant
        fileProof <- right (Kikan.mkDecisionProof (decodeUtf8 fileMinted.token))
        let fileIssued = Kikan.IssuedActionProof fileProof fileMinted.expiresAt [] checkedAt
        _ <- right =<< verifyIssuedAction verifier now fileRequest fileIssued
        changedFileActions <-
          mapM
            right
            [ workspaceSupervisedFileAction (profile & #userId .~ 62002 & #groupId .~ 62002) provisionBinding provisionAdmission dispatch "replace" "src/file" "device:parent" "input-hash",
              workspaceSupervisedFileAction profile provisionBinding provisionAdmission (dispatch & #attemptId .~ AttemptId "other-attempt") "replace" "src/file" "device:parent" "input-hash",
              workspaceSupervisedFileAction profile provisionBinding provisionAdmission dispatch "replace" "src/file" "device:other-parent" "input-hash"
            ]
        mapM_ (\action -> verifyIssuedAction verifier now (fileRequest & #action .~ action) fileIssued >>= \answer -> assertBool "supervised file authority binds reserved identity and actual effect" (case answer of Left Kikan.ProofWrongResource -> True; _ -> False)) changedFileActions
        workspaceSupervisedFileAction profile provisionBinding provisionAdmission dispatch "replace" "src-other/file" "device:parent" "input-hash" @?= Left FileEffectRefused
        workspaceSupervisedFileAction profile provisionBinding (provisionAdmission & #filePolicy .~ Just nativeFilePolicy) dispatch "replace" "src/file" "device:parent" "input-hash" @?= Left FileEffectRefused
        workspaceSupervisedFileAction (profile & #instructionDigest .~ command.profile) provisionBinding provisionAdmission dispatch "replace" "src/file" "device:parent" "input-hash" @?= Left FileEffectRefused
        provisionAction <- right (workspaceProvisionAction provisionBinding provisionAdmission profile boot "device:files" "device:scratch")
        let provisionRequest = Kikan.AuthorizeActionRequest principal provisionAction requestId
            provisionGrant = Grant.EnGrant (SubjectId (ObjectRef (ObjectType "agent") (Kikan.agentPrincipalText principal))) (RelationName (Kikan.actionOperation provisionAction)) (ObjectRef (ObjectType (Kikan.actionObjectType provisionAction)) (Kikan.actionObjectId provisionAction)) (En.ConsistencyToken "snapshot-1") (En.SchemaHash "schema-workspace-fixture") expiry (Grant.Audience "shikigami") (Just (Grant.RequestId "workspace-proof")) Nothing
        provisionMinted <- right =<< mintObjectGrantWithExpiry (MintConfig secret keyId 30 (pure now)) expiry Allowed provisionGrant
        provisionProof <- right (Kikan.mkDecisionProof (decodeUtf8 provisionMinted.token))
        let provisionIssued = Kikan.IssuedActionProof provisionProof provisionMinted.expiresAt [] checkedAt
        _ <- right =<< verifyIssuedAction verifier now provisionRequest provisionIssued
        changedProvision <-
          mapM
            right
            [ workspaceProvisionAction provisionBinding provisionAdmission (profile & #userId .~ 62002 & #groupId .~ 62002) boot "device:files" "device:scratch",
              workspaceProvisionAction provisionBinding (provisionAdmission & #assignmentId .~ "other-assignment") profile boot "device:files" "device:scratch",
              workspaceProvisionAction provisionBinding provisionAdmission profile boot "device:other-files" "device:scratch",
              workspaceProvisionAction provisionBinding provisionAdmission profile boot "device:files" "device:other-scratch",
              workspaceProvisionAction provisionBinding provisionAdmission profile "22222222-2222-4222-8222-222222222222" "device:files" "device:scratch"
            ]
        let changedProcessPolicy = policy & #image . #rootIdentity .~ ("sha256:" <> Text.replicate 64 "b")
            changedProvisionBinding = provisionBinding & #policyRevision .~ processPolicyIdentity changedProcessPolicy
        changedProvisionAdmission <- (\a -> a & #filePolicy .~ Just supervisedFilePolicy) <$> admissionFor changedProvisionBinding
        changedPolicyAction <- right (workspaceProvisionAction changedProvisionBinding changedProvisionAdmission (profileFor changedProvisionBinding changedProvisionAdmission changedProcessPolicy 62001) boot "device:files" "device:scratch")
        mapM_
          (\action -> verifyIssuedAction verifier now (provisionRequest & #action .~ action) provisionIssued >>= \answer -> assertBool "provisioning proof binds identity, policy, assignment, host and anchored roots" (case answer of Left Kikan.ProofWrongResource -> True; _ -> False))
          (changedPolicyAction : changedProvision)
        workspaceProvisionAction provisionBinding (provisionAdmission & #filePolicy .~ Just nativeFilePolicy) profile boot "device:files" "device:scratch" @?= Left FileEffectRefused
        workspaceProvisionAction provisionBinding provisionAdmission (profile & #instructionDigest .~ command.profile) boot "device:files" "device:scratch" @?= Left FileEffectRefused
        let gitLogical = logical & #fingerprint .~ command.profile & #scopeDigest .~ command.profile
            gitDispatch = dispatch & #operation .~ gitLogical
            candidate = Git.GitCandidate provisionBinding.base (Text.replicate 40 "b") (Text.replicate 40 "c") ["src/file"]
            rawGit = Git.GitRecord 1 gitLogical gitDispatch.attemptId gitDispatch.owner gitDispatch.generation (workspaceBindingDigest provisionBinding) (bundleDigest provisionAdmission.instructions) (Git.gitProfileDigest profile) "device:files" provisionBinding.base command.profile now (Git.GitRouting gitLogical.executionId owner command.profile NeedModel) Git.GitPrepared (Just candidate)
            seal value = value & #fingerprint .~ Git.gitFingerprint provisionBinding value
            gitRecord = seal rawGit
            gitAction a d p value = workspaceGitAction provisionBinding a d p (seal value)
        commitAction <- right (gitAction provisionAdmission gitDispatch profile gitRecord)
        workspaceGitAction provisionBinding provisionAdmission gitDispatch profile (gitRecord & #phase .~ Git.GitPublishRequested) @?= Right commitAction
        let commitRequest = Kikan.AuthorizeActionRequest principal commitAction requestId
            commitGrant = Grant.EnGrant (SubjectId (ObjectRef (ObjectType "agent") (Kikan.agentPrincipalText principal))) (RelationName (Kikan.actionOperation commitAction)) (ObjectRef (ObjectType (Kikan.actionObjectType commitAction)) (Kikan.actionObjectId commitAction)) (En.ConsistencyToken "snapshot-1") (En.SchemaHash "schema-workspace-fixture") expiry (Grant.Audience "shikigami") (Just (Grant.RequestId "workspace-proof")) Nothing
        commitMinted <- right =<< mintObjectGrantWithExpiry (MintConfig secret keyId 30 (pure now)) expiry Allowed commitGrant
        commitProof <- right (Kikan.mkDecisionProof (decodeUtf8 commitMinted.token))
        let commitIssued = Kikan.IssuedActionProof commitProof commitMinted.expiresAt [] checkedAt
            changedProfile = profile & #userId .~ 62002 & #groupId .~ 62002
        _ <- right =<< verifyIssuedAction verifier now commitRequest commitIssued
        changedGitActions <-
          mapM
            right
            [ gitAction provisionAdmission gitDispatch profile (gitRecord & #target .~ "device:other-files"),
              gitAction provisionAdmission gitDispatch profile (gitRecord & #createdAt .~ addUTCTime 1 now),
              gitAction provisionAdmission gitDispatch profile (gitRecord & #candidate .~ Just (candidate & #tree .~ Text.replicate 40 "d")),
              gitAction provisionAdmission gitDispatch profile (gitRecord & #candidate .~ Just (candidate & #result .~ Text.replicate 40 "d")),
              gitAction provisionAdmission gitDispatch profile (gitRecord & #candidate .~ Just (candidate & #paths .~ ["src/other"])),
              gitAction provisionAdmission gitDispatch profile (gitRecord & #expectedParent .~ Text.replicate 40 "d" & #candidate .~ Just (candidate & #parent .~ Text.replicate 40 "d")),
              gitAction provisionAdmission gitDispatch profile (gitRecord & #routing . #inputDigest .~ ("sha256:" <> Text.replicate 64 "b")),
              gitAction (provisionAdmission & #assignmentId .~ "other-assignment") gitDispatch profile gitRecord,
              gitAction provisionAdmission (gitDispatch & #attemptId .~ AttemptId "other-attempt") profile (gitRecord & #attemptId .~ AttemptId "other-attempt"),
              gitAction provisionAdmission (gitDispatch & #owner .~ "other-claim") profile (gitRecord & #claimOwner .~ "other-claim"),
              gitAction provisionAdmission (gitDispatch & #generation .~ 2) profile (gitRecord & #generation .~ 2),
              gitAction provisionAdmission gitDispatch changedProfile (gitRecord & #profileDigest .~ Git.gitProfileDigest changedProfile),
              gitAction provisionAdmission gitDispatch profile (gitRecord & #phase .~ Git.GitReserved & #candidate .~ Nothing)
            ]
        mapM_ (\action -> verifyIssuedAction verifier now (commitRequest & #action .~ action) commitIssued >>= \answer -> assertBool "Git proof binds exact plan, profile, input, anchor and actual claim" (case answer of Left Kikan.ProofWrongResource -> True; _ -> False)) changedGitActions
        workspaceGitAction provisionBinding (provisionAdmission & #filePolicy .~ Just nativeFilePolicy) gitDispatch profile gitRecord @?= Left FileEffectRefused
        workspaceGitAction provisionBinding provisionAdmission gitDispatch profile (gitRecord & #phase .~ Git.GitUnresolved) @?= Left FileEffectRefused
        workspaceGitAction provisionBinding provisionAdmission gitDispatch profile (gitRecord & #attemptId .~ AttemptId "unmatched") @?= Left FileEffectRefused
        gitAction provisionAdmission gitDispatch profile (gitRecord & #candidate .~ Just (candidate & #paths .~ ["outside-policy"])) @?= Left FileEffectRefused
    ]

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure
