{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | Pure operator catalog construction and fail-closed overlay resolution.
-- Live providers and leases belong to the separate runtime registry.
module Shikigami.Capability.Catalog
  ( CapabilityCatalog,
    CapabilityCatalogError (..),
    mkCapabilityCatalog,
    emptyCapabilityCatalog,
    lookupCapability,
    listCapabilities,
    ExecutionMode (..),
    ResolutionSubject (..),
    CapabilityResolutionError (..),
    resolveCapabilityOverlays,
  )
where

import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Shikigami.Agent.Decl (Behavior (..))
import Shikigami.Attestation.Resolve (ResolvedProfile)
import Shikigami.Capability.Overlay
import Shikigami.Prelude

newtype CapabilityCatalog = CapabilityCatalog (Map CapabilityId CapabilityDescriptor)
  deriving stock (Eq, Show)

data CapabilityCatalogError
  = DuplicateCapability {capability :: !CapabilityId}
  | EmptyCapabilityToolSet {capability :: !CapabilityId}
  | EmptyCapabilityToolName {capability :: !CapabilityId}
  | DuplicateCapabilityToolName {capability :: !CapabilityId, name :: !Text}
  deriving stock (Eq, Show, Generic)

mkCapabilityCatalog :: [CapabilityDescriptor] -> Either CapabilityCatalogError CapabilityCatalog
mkCapabilityCatalog descriptors = CapabilityCatalog <$> foldl' addDescriptor (Right Map.empty) descriptors
  where
    addDescriptor accumulated descriptor@CapabilityDescriptor {capability} = do
      catalog <- accumulated
      validateDescriptor descriptor
      case Map.lookup capability catalog of
        Just _ -> Left DuplicateCapability {capability}
        Nothing -> Right (Map.insert capability descriptor catalog)

emptyCapabilityCatalog :: CapabilityCatalog
emptyCapabilityCatalog = CapabilityCatalog Map.empty

validateDescriptor :: CapabilityDescriptor -> Either CapabilityCatalogError ()
validateDescriptor CapabilityDescriptor {capability, tools}
  | null tools = Left EmptyCapabilityToolSet {capability}
  | otherwise = validateToolNames capability tools

validateToolNames :: CapabilityId -> [CapabilityToolDescriptor] -> Either CapabilityCatalogError ()
validateToolNames capability = go Set.empty
  where
    go :: Set Text -> [CapabilityToolDescriptor] -> Either CapabilityCatalogError ()
    go _ [] = Right ()
    go seen (CapabilityToolDescriptor {name} : rest)
      | name == "" = Left EmptyCapabilityToolName {capability}
      | name `Set.member` seen = Left DuplicateCapabilityToolName {capability, name}
      | otherwise = go (Set.insert name seen) rest

lookupCapability :: CapabilityCatalog -> CapabilityId -> Maybe CapabilityDescriptor
lookupCapability (CapabilityCatalog catalog) capability = Map.lookup capability catalog

listCapabilities :: CapabilityCatalog -> [CapabilityDescriptor]
listCapabilities (CapabilityCatalog catalog) = Map.elems catalog

data ExecutionMode = Durable | OneOff
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ResolutionSubject = ResolutionSubject
  { principal :: !(Maybe Text),
    mode :: !ExecutionMode,
    behavior :: !Behavior,
    -- | The already journaled sanctioned-profile snapshot, when the agent
    -- requested one. Capability policy receives this value rather than reading
    -- mutable profile state independently.
    profile :: !(Maybe ResolvedProfile)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Permanent, public refusals produced before any provider is acquired.
data CapabilityResolutionError
  = DuplicateCapabilityRequest {capability :: !CapabilityId}
  | UnknownCapability {capability :: !CapabilityId}
  | MissingCapabilityIdentity
  | CapabilityAuthorizationDenied {capability :: !CapabilityId, reason :: !Text}
  | CapabilityBehaviorUnsupported {behaviorKind :: !Text}
  | DurableCapabilityOperationNotAllowed
      { capability :: !CapabilityId,
        name :: !Text,
        operationClass :: !CapabilityOperationClass
      }
  deriving stock (Eq, Show, Generic)

instance ToJSON CapabilityResolutionError where
  toJSON = \case
    DuplicateCapabilityRequest {capability} ->
      Aeson.object ["type" Aeson..= ("duplicate-request" :: Text), "capability" Aeson..= capability]
    UnknownCapability {capability} ->
      Aeson.object ["type" Aeson..= ("unknown-capability" :: Text), "capability" Aeson..= capability]
    MissingCapabilityIdentity ->
      Aeson.object ["type" Aeson..= ("missing-identity" :: Text)]
    CapabilityAuthorizationDenied {capability, reason} ->
      Aeson.object
        [ "type" Aeson..= ("authorization-denied" :: Text),
          "capability" Aeson..= capability,
          "reason" Aeson..= reason
        ]
    CapabilityBehaviorUnsupported {behaviorKind} ->
      Aeson.object
        [ "type" Aeson..= ("behavior-unsupported" :: Text),
          "behavior" Aeson..= behaviorKind
        ]
    DurableCapabilityOperationNotAllowed {capability, name, operationClass} ->
      Aeson.object
        [ "type" Aeson..= ("durable-operation-not-allowed" :: Text),
          "capability" Aeson..= capability,
          "tool" Aeson..= name,
          "operationClass" Aeson..= operationClass
        ]

instance FromJSON CapabilityResolutionError where
  parseJSON = Aeson.withObject "CapabilityResolutionError" \value -> do
    tag <- value Aeson..: "type"
    case (tag :: Text) of
      "duplicate-request" -> DuplicateCapabilityRequest <$> value Aeson..: "capability"
      "unknown-capability" -> UnknownCapability <$> value Aeson..: "capability"
      "missing-identity" -> pure MissingCapabilityIdentity
      "authorization-denied" ->
        CapabilityAuthorizationDenied
          <$> value Aeson..: "capability"
          <*> value Aeson..: "reason"
      "behavior-unsupported" -> CapabilityBehaviorUnsupported <$> value Aeson..: "behavior"
      "durable-operation-not-allowed" ->
        DurableCapabilityOperationNotAllowed
          <$> value Aeson..: "capability"
          <*> value Aeson..: "tool"
          <*> value Aeson..: "operationClass"
      _ -> fail ("unknown capability resolution error type: " <> show tag)

resolveCapabilityOverlays ::
  CapabilityCatalog ->
  (ResolutionSubject -> CapabilityDescriptor -> Either CapabilityResolutionError ()) ->
  ResolutionSubject ->
  [CapabilityId] ->
  Either CapabilityResolutionError ResolvedCapabilitySet
resolveCapabilityOverlays catalog authorize subject@ResolutionSubject {principal, mode, behavior} requested
  | null requested = Right emptyResolvedCapabilitySet
  | Just duplicate <- firstDuplicate requested = Left DuplicateCapabilityRequest {capability = duplicate}
  | principal == Nothing = Left MissingCapabilityIdentity
  | behaviorKindText behavior /= "Skill" = Left CapabilityBehaviorUnsupported {behaviorKind = behaviorKindText behavior}
  | otherwise = do
      descriptors <- traverse resolveOne requested
      traverse_ (admitOperationClass mode) descriptors
      traverse_ (authorize subject) descriptors
      pure (mkResolvedCapabilitySet descriptors)
  where
    resolveOne capability =
      maybe
        (Left UnknownCapability {capability})
        Right
        (lookupCapability catalog capability)

firstDuplicate :: (Ord value) => [value] -> Maybe value
firstDuplicate = go Set.empty
  where
    go _ [] = Nothing
    go seen (value : rest)
      | value `Set.member` seen = Just value
      | otherwise = go (Set.insert value seen) rest

admitOperationClass :: ExecutionMode -> CapabilityDescriptor -> Either CapabilityResolutionError ()
admitOperationClass OneOff _ = Right ()
admitOperationClass Durable CapabilityDescriptor {capability, tools} = go tools
  where
    go [] = Right ()
    go (CapabilityToolDescriptor {name, operationClass} : rest) =
      case operationClass of
        Observation -> go rest
        _ -> Left DurableCapabilityOperationNotAllowed {capability, name, operationClass}

behaviorKindText :: Behavior -> Text
behaviorKindText = \case
  Deterministic {} -> "Deterministic"
  ShikumiProgram {} -> "ShikumiProgram"
  Skill {} -> "Skill"
  CoordinatingSkill {} -> "Skill"
  Flow {} -> "Flow"
