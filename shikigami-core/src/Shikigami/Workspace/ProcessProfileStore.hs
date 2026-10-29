-- | Reserve a workspace-specific Unix identity and complete operator policy
-- before provisioning. Identities are not recycled by expiry or reboot.
module Shikigami.Workspace.ProcessProfileStore (reserveProcessProfileTx, inspectProcessProfileTx, readyProcessProfileTx) where

import Contravariant.Extras (contrazip2, contrazip3)
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Shikigami.Execution.Identity (OperationId (..))
import Shikigami.Prelude
import Shikigami.Workspace.Process (digestText)
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.Reference (WorkspaceRef (..))
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Types

reserveProcessProfileTx :: WorkspaceBinding -> Text -> ProcessPolicy -> IdentityRange -> Transaction (Either WorkspaceError (ProcessProfile, ProfileState))
reserveProcessProfileTx binding instructions policy range
  | not (validProcessPolicy policy && validIdentityRange range && digestText instructions && binding.policyRevision == processPolicyIdentity policy) = pure (Left InvalidWorkspaceRequest)
  | otherwise = do
      owner <- Store.checkWorkspaceOwnerTx binding binding.request.owner binding.request.epoch
      case owner of
        Left err -> pure (Left err)
        Right () -> do
          previous <- inspectProcessProfileTx binding.workspace
          case previous of
            Just retained@(profile, _) | matches profile -> pure (Right retained)
            Just _ -> pure (Left WorkspaceBindingConflict)
            Nothing -> do
              available <- Store.checkWorkspaceOperationTx binding binding.request.owner binding.request.epoch (OperationId "workspace-profile-admission")
              case available of
                Left err -> pure (Left err)
                Right () -> do
                  -- A dedicated singleton row serializes different workspaces
                  -- competing for the operator's reserved identity pool.
                  _ <- Tx.statement () lockAllocator
                  identity <- Tx.statement (range.firstId, range.lastId) nextIdentity
                  case identity of
                    Nothing -> pure (Left WorkspaceAllocationRefused)
                    Just uid -> do
                      let profile = ProcessProfile (workspaceBindingDigest binding) instructions policy uid uid
                      Tx.statement (binding.workspace.resource, uid, profile) insertProfile
                      pure (Right (profile, ProfileReserved))
  where
    matches profile = validProcessProfile profile && profile.bindingDigest == workspaceBindingDigest binding && profile.instructionDigest == instructions && processPolicyIdentity profile.policy == processPolicyIdentity policy && profile.userId >= range.firstId && profile.userId <= range.lastId

inspectProcessProfileTx :: WorkspaceRef -> Transaction (Maybe (ProcessProfile, ProfileState))
inspectProcessProfileTx workspace
  | workspace.provider /= "shikigami.workspace/1" = pure Nothing
  | otherwise = Tx.statement workspace.resource selectProfile

-- This only records the trusted provisioner's completed work. It supplies no
-- process settlement proof or permission to execute repository code.
readyProcessProfileTx :: WorkspaceBinding -> ProcessProfile -> Transaction (Either WorkspaceError ())
readyProcessProfileTx binding profile
  | not (validProcessProfile profile && profile.bindingDigest == workspaceBindingDigest binding && processPolicyIdentity profile.policy == binding.policyRevision) = pure (Left WorkspaceBindingConflict)
  | otherwise = do
      checked <- Store.checkWorkspaceOperationTx binding binding.request.owner binding.request.epoch (OperationId "workspace-profile-admission")
      case checked of
        Left err -> pure (Left err)
        Right () -> do
          changed <- Tx.statement (binding.workspace.resource, profile) readyProfile
          pure (if changed then Right () else Left WorkspaceBindingConflict)

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

intParam :: E.Params Int
intParam = fromIntegral >$< E.param (E.nonNullable E.int4)

profileParam :: E.Params ProcessProfile
profileParam = toJSON >$< E.param (E.nonNullable E.jsonb)

lockAllocator :: Statement () Bool
lockAllocator = preparable "SELECT singleton FROM shikigami.workspace_profile_allocator WHERE singleton FOR UPDATE" E.noParams (D.singleRow (D.column (D.nonNullable D.bool)))

nextIdentity :: Statement (Int, Int) (Maybe Int)
nextIdentity = preparable "SELECT uid FROM generate_series($1,$2) AS candidates(uid) WHERE NOT EXISTS(SELECT 1 FROM shikigami.workspace_process_profiles p WHERE p.user_id=candidates.uid) ORDER BY uid LIMIT 1" (contrazip2 intParam intParam) (D.rowMaybe (fromIntegral <$> D.column (D.nonNullable D.int4)))

insertProfile :: Statement (Text, Int, ProcessProfile) ()
insertProfile = preparable "INSERT INTO shikigami.workspace_process_profiles(resource,user_id,profile) VALUES($1,$2,$3)" (contrazip3 textParam intParam profileParam) D.noResult

selectProfile :: Statement Text (Maybe (ProcessProfile, ProfileState))
selectProfile = preparable "SELECT profile,ready FROM shikigami.workspace_process_profiles WHERE resource=$1 FOR UPDATE" textParam (D.rowMaybe ((,) <$> profileColumn <*> ((\ready -> if ready then ProfileReady else ProfileReserved) <$> D.column (D.nonNullable D.bool))))

profileColumn :: D.Row ProcessProfile
profileColumn = D.column (D.nonNullable (D.refine decode D.jsonb))
  where
    decode value = case Aeson.fromJSON value of
      Aeson.Success profile | validProcessProfile profile -> Right profile
      _ -> Left "invalid workspace process profile"

readyProfile :: Statement (Text, ProcessProfile) Bool
readyProfile = preparable "UPDATE shikigami.workspace_process_profiles SET ready=true WHERE resource=$1 AND profile=$2 RETURNING true" (contrazip2 textParam profileParam) (maybe False id <$> D.rowMaybe (D.column (D.nonNullable D.bool)))
