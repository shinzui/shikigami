{-# LANGUAGE DataKinds #-}

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
import Shikigami.Execution.Identity (operationIdFromNonEmpty)
import Shikigami.Prelude
import Shikigami.Workspace.Process (digestText)
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.Reference (WorkspaceRef (..))
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Types
import Shikigami.Workspace.Value

reserveProcessProfileTx :: WorkspaceBinding -> WorkspaceCoordinate "instructions-digest" -> ProcessPolicy -> IdentityRange -> Transaction (Either WorkspaceError (ProcessProfile, ProfileState))
reserveProcessProfileTx binding instructions policy range
  | not (validProcessPolicy policy && validIdentityRange range && digestText (workspaceCoordinateText instructions) && binding.policyRevision == processPolicyIdentity policy) = pure (Left InvalidWorkspaceRequest)
  | otherwise = do
      owner <- Store.checkWorkspaceOwnerTx binding binding.request.owner binding.request.epoch
      case owner of
        Left err -> pure (Left err)
        Right () -> do
          previous <- inspectProcessProfileTx binding.workspace
          case previous of
            Left err -> pure (Left err)
            Right (Just retained@(profile, _)) | matches profile -> pure (Right retained)
            Right (Just _) -> pure (Left WorkspaceBindingConflict)
            Right Nothing -> do
              available <- Store.checkWorkspaceOperationTx binding binding.request.owner binding.request.epoch (operationIdFromNonEmpty ('w' :| "orkspace-profile-admission"))
              case available of
                Left err -> pure (Left err)
                Right () -> do
                  -- A dedicated singleton row serializes different workspaces
                  -- competing for the operator's reserved identity pool.
                  _ <- Tx.statement () lockAllocator
                  identity <- Tx.statement (workspaceIdentityNumber range.firstId, workspaceIdentityNumber range.lastId) nextIdentity
                  case identity of
                    Nothing -> pure (Left WorkspaceAllocationRefused)
                    Just raw -> case parseWorkspaceIdentity raw of
                      Left _ -> Tx.condemn >> pure (Left WorkspaceBindingConflict)
                      Right uid -> do
                        let profile = ProcessProfile (workspaceBindingDigest binding) instructions policy uid uid
                        Tx.statement (workspaceCoordinateText binding.workspace.resource, workspaceIdentityNumber uid, profile) insertProfile
                        pure (Right (profile, ProfileReserved))
  where
    matches profile = validProcessProfile profile && profile.bindingDigest == workspaceBindingDigest binding && profile.instructionDigest == instructions && processPolicyIdentity profile.policy == processPolicyIdentity policy && profile.userId >= range.firstId && profile.userId <= range.lastId

inspectProcessProfileTx :: WorkspaceRef -> Transaction (Either WorkspaceError (Maybe (ProcessProfile, ProfileState)))
inspectProcessProfileTx workspace
  | workspace.provider /= workspaceCoordinate "shikigami.workspace/1" = pure (Right Nothing)
  | otherwise = do
      retained <- Tx.statement (workspaceCoordinateText workspace.resource) selectProfile
      case retained of
        Nothing -> pure (Right Nothing)
        Just (value, state) -> case Aeson.fromJSON value of
          Aeson.Success profile | validProcessProfile profile -> pure (Right (Just (profile, state)))
          _ -> do
            -- A caller may ignore the refusal after making an earlier write.
            -- Retained identity/policy corruption must still roll it all back.
            Tx.condemn
            pure (Left WorkspaceBindingConflict)

-- This only records the trusted provisioner's completed work. It supplies no
-- process settlement proof or permission to execute repository code.
readyProcessProfileTx :: WorkspaceBinding -> ProcessProfile -> Transaction (Either WorkspaceError ())
readyProcessProfileTx binding profile
  | not (validProcessProfile profile && profile.bindingDigest == workspaceBindingDigest binding && processPolicyIdentity profile.policy == binding.policyRevision) = pure (Left WorkspaceBindingConflict)
  | otherwise = do
      checked <- Store.checkWorkspaceOperationTx binding binding.request.owner binding.request.epoch (operationIdFromNonEmpty ('w' :| "orkspace-profile-admission"))
      case checked of
        Left err -> pure (Left err)
        Right () -> do
          retained <- inspectProcessProfileTx binding.workspace
          case retained of
            Left err -> pure (Left err)
            Right (Just (original, _)) | original == profile -> do
              changed <- Tx.statement (workspaceCoordinateText binding.workspace.resource, profile) readyProfile
              pure (if changed then Right () else Left WorkspaceBindingConflict)
            _ -> pure (Left WorkspaceBindingConflict)

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

selectProfile :: Statement Text (Maybe (Aeson.Value, ProfileState))
selectProfile = preparable "SELECT profile,ready FROM shikigami.workspace_process_profiles WHERE resource=$1 FOR UPDATE" textParam (D.rowMaybe ((,) <$> D.column (D.nonNullable D.jsonb) <*> ((\ready -> if ready then ProfileReady else ProfileReserved) <$> D.column (D.nonNullable D.bool))))

readyProfile :: Statement (Text, ProcessProfile) Bool
readyProfile = preparable "UPDATE shikigami.workspace_process_profiles SET ready=true WHERE resource=$1 AND profile=$2 RETURNING true" (contrazip2 textParam profileParam) (maybe False id <$> D.rowMaybe (D.column (D.nonNullable D.bool)))
