-- | The identity recorded at Shikigami's durable boundaries.
--
-- A declaration name is an address. A verified Meibo principal is the durable
-- subject. Directory-disabled development remains possible, but its
-- self-asserted identity is a different constructor and wire value so it cannot
-- be mistaken for verified execution.
module Shikigami.Agent.Principal
  ( AgentPrincipal,
    AgentIdentity (..),
    ResolvedAgentIdentity (..),
    mkAgentPrincipal,
    principalText,
    compatibilityIdentity,
    resolveAgentIdentity,
    resolvedIdentity,
    resolvedIdentityText,
    identityText,
    meiboPrincipal,
    principalRefFor,
    principalScopeText,
  )
where

import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Kioku.Api.Access (PrincipalRef, mkPrincipalRef)
import Shikigami.Prelude hiding ((.=))

-- | An immutable Meibo agent principal, retaining its canonical rendered form.
newtype AgentPrincipal = AgentPrincipal {value :: Text}
  deriving stock (Eq, Ord, Show)

-- | Identity carried by queued work, workflow input, memory, grants, and
-- outbound intents.
--
-- 'UnresolvedLegacyIdentity' is decode-side compatibility only. Fresh work must
-- be admitted to one of the other constructors before it can perform an effect.
data AgentIdentity
  = VerifiedIdentity !AgentPrincipal
  | CompatibilityIdentity !Text
  | UnresolvedLegacyIdentity
  deriving stock (Eq, Ord, Show, Generic)

-- | An identity proven suitable for a fresh effect.
data ResolvedAgentIdentity
  = VerifiedAgent !AgentPrincipal
  | CompatibilityAgent !Text
  deriving stock (Eq, Ord, Show, Generic)

instance ToJSON AgentIdentity where
  toJSON = \case
    VerifiedIdentity principal ->
      Aeson.object
        [ "kind" .= ("verified" :: Text),
          "principalId" .= principalText principal
        ]
    CompatibilityIdentity agentName ->
      Aeson.object
        [ "kind" .= ("compatibility" :: Text),
          "agentName" .= agentName
        ]
    UnresolvedLegacyIdentity ->
      Aeson.object ["kind" .= ("unresolved-legacy" :: Text)]

instance FromJSON AgentIdentity where
  parseJSON = Aeson.withObject "AgentIdentity" \object -> do
    kind <- object .: "kind"
    case kind :: Text of
      "verified" -> do
        raw <- object .: "principalId"
        either (fail . Text.unpack) (pure . VerifiedIdentity) (mkAgentPrincipal raw)
      "compatibility" -> compatibilityIdentity <$> object .: "agentName"
      "unresolved-legacy" -> pure UnresolvedLegacyIdentity
      other -> fail ("unknown agent identity kind: " <> Text.unpack other)

-- | Validate the directory-issued textual form and Kioku's principal syntax.
mkAgentPrincipal :: Text -> Either Text AgentPrincipal
mkAgentPrincipal raw
  | not ("agent_" `Text.isPrefixOf` raw) = Left "agent principal must start with agent_"
  | Text.length raw <= Text.length ("agent_" :: Text) = Left "agent principal is missing its identifier"
  | otherwise = do
      _ <- mkPrincipalRef raw
      pure (AgentPrincipal raw)

principalText :: AgentPrincipal -> Text
principalText (AgentPrincipal raw) = raw

-- | Construct the explicit identity used only when the directory is disabled.
compatibilityIdentity :: Text -> AgentIdentity
compatibilityIdentity = CompatibilityIdentity

-- | The stable text used for attribution and scope keys.
identityText :: AgentIdentity -> Either Text Text
identityText identity = resolvedIdentityText <$> resolveAgentIdentity identity

resolveAgentIdentity :: AgentIdentity -> Either Text ResolvedAgentIdentity
resolveAgentIdentity = \case
  VerifiedIdentity principal -> Right (VerifiedAgent principal)
  CompatibilityIdentity agentName -> Right (CompatibilityAgent agentName)
  UnresolvedLegacyIdentity -> Left "legacy run has not been assigned an agent identity"

resolvedIdentity :: ResolvedAgentIdentity -> AgentIdentity
resolvedIdentity = \case
  VerifiedAgent principal -> VerifiedIdentity principal
  CompatibilityAgent agentName -> CompatibilityIdentity agentName

resolvedIdentityText :: ResolvedAgentIdentity -> Text
resolvedIdentityText = \case
  VerifiedAgent principal -> principalText principal
  CompatibilityAgent agentName -> "shikigami.agent." <> sanitize agentName
  where
    sanitize = Text.map \case
      ':' -> '.'
      '#' -> '.'
      '%' -> '.'
      '/' -> '.'
      character -> character

meiboPrincipal :: AgentIdentity -> Maybe AgentPrincipal
meiboPrincipal = \case
  VerifiedIdentity principal -> Just principal
  CompatibilityIdentity _ -> Nothing
  UnresolvedLegacyIdentity -> Nothing

principalRefFor :: ResolvedAgentIdentity -> PrincipalRef
principalRefFor identity =
  case mkPrincipalRef (resolvedIdentityText identity) of
    Right principal -> principal
    Left problem -> error ("validated agent identity became an invalid Kioku principal: " <> Text.unpack problem)

principalScopeText :: ResolvedAgentIdentity -> Text
principalScopeText = resolvedIdentityText
