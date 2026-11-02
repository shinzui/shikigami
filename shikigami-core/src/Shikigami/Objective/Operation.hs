{-# LANGUAGE DataKinds #-}

-- | Shared scoped adapter for native tools and typed Flows. The command owner
-- remains responsible for authentication, current roles and immutable receipts.
module Shikigami.Objective.Operation where

import Control.Exception (throwIO)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Shikigami.Behavior.Error (TransientBehaviorFailure (..))
import Shikigami.Execution.Identity (OperationId)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Objective.Capability qualified as Owner
import Shikigami.Objective.Command (Command)
import Shikigami.Objective.Inspection (ObjectiveView, objectiveViewPage)
import Shikigami.Objective.Origin qualified as Origin
import Shikigami.Objective.Runtime qualified as Runtime
import Shikigami.Objective.Scope qualified as Scope
import Shikigami.Objective.Types
import Shikigami.Prelude

-- No decoder: native/model JSON uses the narrower Objective.Tools.Input sum.
data Request
  = CreateObjective !CreateRequest
  | InspectObjective !ObjectiveId !Int !Int
  | ApplyObjectiveCommand !ObjectiveId !(StateRevision "objective") !Command
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

instance Show Request where show _ = "ObjectiveRequest <protected>"

data Result = ObjectiveCreated !Receipt | ObjectiveInspected !ObjectiveView | ObjectiveUpdated !Receipt
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show Result where show _ = "ObjectiveResult <protected>"

data Reply = Reply {format :: !(FormatVersion "objective-reply"), result :: !Result}
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show Reply where show _ = "ObjectiveReply <protected>"

execute :: Runtime.ObjectiveRuntime -> Scope.ObjectiveScope -> Origin.OriginAuthority -> OperationId -> Request -> IO (Either ObjectiveError Reply)
execute runtime scope origin operation request
  | not (Scope.validScope scope) = pure (Left ObjectiveDenied)
  | required request `notElem` scope.permissions = pure (Left ObjectiveDenied)
  | otherwise = do
      current <- Runtime.validateRetainedScope runtime scope
      exact <- Runtime.authorizeScope runtime scope "command" (toJSON (operation, request))
      case current >> exact of
        Left err -> pure (Left err)
        Right () -> do
          result <- Runtime.owned runtime case request of
            CreateObjective body -> fmap ObjectiveCreated <$> Owner.createObjective host operation (Just (Origin.authorityOrigin origin)) body
            InspectObjective objective after limit
              | after < 0 || after > 10000 || limit < 1 || limit > 100 -> pure (Left (ObjectiveInvalid "invalid objective page bounds"))
              | otherwise ->
                  target objective >>= \case
                    Left err -> pure (Left err)
                    Right () -> fmap (ObjectiveInspected . objectiveViewPage after limit) <$> Owner.readObjective host objective
            ApplyObjectiveCommand objective expected command ->
              target objective >>= \case
                Left err -> pure (Left err)
                Right () -> fmap ObjectiveUpdated <$> Owner.executeCommand host objective expected operation command
          pure (bounded (Reply V1 <$> result))
  where
    host = (Runtime.hostFor runtime scope.identity) {Owner.verifyOrigin = \actor candidate -> Runtime.owned runtime (Origin.verifyCreationOrigin origin actor candidate)}
    target objective
      | scope.target == Just objective = pure (Right ())
      | Scope.CreateObjectives `elem` scope.permissions = Origin.lookupCreatedInScope origin host objective <&> (>>= maybe (Left ObjectiveDenied) (const (Right ())))
      | otherwise = pure (Left ObjectiveDenied)
    required = \case CreateObjective {} -> Scope.CreateObjectives; InspectObjective {} -> Scope.InspectObjectives; ApplyObjectiveCommand {} -> Scope.ApplyObjectiveCommands

bounded :: Either ObjectiveError Reply -> Either ObjectiveError Reply
bounded reply
  | Lazy.length (Aeson.encode reply) <= 16384 = reply
  | otherwise = Left (ObjectiveInvalid "objective reply exceeds 16 KiB; use a smaller page or authenticated API inspection")

-- An unavailable command owner might already have committed. Do not journal a
-- definitive failure or give the model a new operation key. Both durable paths
-- retry the same accepted operation and recover its original receipt.
requireResolved :: Either ObjectiveError a -> IO (Either ObjectiveError a)
requireResolved = \case
  Left ObjectiveUnavailable -> throwIO (TransientBehaviorFailure "objective command outcome is unavailable")
  Left ObjectiveUnresolved -> throwIO (TransientBehaviorFailure "objective command outcome remains unresolved")
  outcome -> pure outcome
