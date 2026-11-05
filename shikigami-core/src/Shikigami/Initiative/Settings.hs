{-# LANGUAGE DataKinds #-}

-- | Observer allowances: operator-owned attention and spend authority. An
-- allowance is not objective creation authority and not admission authority.
module Shikigami.Initiative.Settings
  ( InitiativeSettings (..),
    ObserverAllowance (..),
    EvaluationEnvelope (..),
    NoticeTarget (..),
    defaultMaximumPolicyLifetime,
    resolveAllowance,
    evaluationEnvelopeAt,
    allowanceView,
    renderLimits,
    parseLimits,
  )
where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (String), object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.List (find, nub)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime)
import GHC.Generics (Generic)
import Shikigami.Agent.DeclarationValue (DeclarationCoordinate)
import Shikigami.Agent.Principal (AgentIdentity, AgentPrincipal, identityText, mkAgentPrincipal, principalText)
import Shikigami.Duration (Duration, durationTime, remainingDuration)
import Shikigami.Execution.Resources (Dimension (..), Envelope (..), Limit (..), Limits)
import Shikigami.Initiative.Types

data InitiativeSettings = InitiativeSettings
  { observers :: ![ObserverAllowance],
    maximumPolicyLifetime :: !(Duration "initiative-policy-lifetime")
  }
  deriving stock (Eq, Show, Generic)

data ObserverAllowance = ObserverAllowance
  { principal :: !AgentPrincipal,
    sources :: !(NonEmpty SourceKind),
    minimumExcerptLength :: !(InitiativeLimit "minimumExcerptLength"),
    evaluation :: !EvaluationEnvelope,
    evaluationsPerWindow :: !(InitiativeLimit "evaluationsPerWindow"),
    proposalsPerWindow :: !(InitiativeLimit "proposalsPerWindow"),
    notificationsPerWindow :: !(InitiativeLimit "notificationsPerWindow"),
    window :: !(Duration "initiative-window"),
    proposalExpiry :: !(Duration "initiative-proposal"),
    rejectionSuppression :: !(Duration "initiative-suppression"),
    notices :: !NoticeTarget
  }
  deriving stock (Eq, Show, Generic)

-- | The dimension limits and lifetime of the resource root one evaluation runs under.
data EvaluationEnvelope = EvaluationEnvelope
  { limits :: !Limits,
    cutoff :: !(Duration "initiative-evaluation")
  }
  deriving stock (Eq, Show, Generic)

-- | The closed set of places an admission notice can go.
newtype NoticeTarget = KizashiRecipient (DeclarationCoordinate "recipient")
  deriving stock (Eq, Show, Generic)

defaultMaximumPolicyLifetime :: Duration "initiative-policy-lifetime"
defaultMaximumPolicyLifetime = remainingDuration (30 * 24 * 60 * 60)

positive :: Duration scope -> Parser ()
positive duration = unless (durationTime duration > 0) (fail "initiative durations must be positive")

instance ToJSON InitiativeSettings where
  toJSON settings = object ["observers" .= settings.observers, "maximumPolicyLifetime" .= settings.maximumPolicyLifetime]

instance FromJSON InitiativeSettings where
  parseJSON = withObject "initiatives" \fields -> do
    unless (all (`elem` ["observers", "maximumPolicyLifetime"]) (KeyMap.keys fields)) (fail "unknown initiative setting")
    observers <- fields .: "observers"
    maximumPolicyLifetime <- fields .:? "maximumPolicyLifetime" .!= defaultMaximumPolicyLifetime
    positive maximumPolicyLifetime
    let principals = map (.principal) observers
    unless (length observers <= 256) (fail "at most 256 observer allowances are accepted")
    unless (length (nub principals) == length principals) (fail "duplicate observer allowance principal")
    pure InitiativeSettings {observers, maximumPolicyLifetime}

instance ToJSON ObserverAllowance where
  toJSON allowance =
    object
      [ "principal" .= principalText allowance.principal,
        "sources" .= allowance.sources,
        "minimumExcerptLength" .= allowance.minimumExcerptLength,
        "evaluation" .= allowance.evaluation,
        "evaluationsPerWindow" .= allowance.evaluationsPerWindow,
        "proposalsPerWindow" .= allowance.proposalsPerWindow,
        "notificationsPerWindow" .= allowance.notificationsPerWindow,
        "window" .= allowance.window,
        "proposalExpiry" .= allowance.proposalExpiry,
        "rejectionSuppression" .= allowance.rejectionSuppression,
        "notices" .= allowance.notices
      ]

instance FromJSON ObserverAllowance where
  parseJSON = withObject "observer allowance" \fields -> do
    unless (all (`elem` accepted) (KeyMap.keys fields)) (fail "unknown observer allowance setting")
    allowance <-
      ObserverAllowance
        <$> (fields .: "principal" >>= either (fail . Text.unpack) pure . mkAgentPrincipal)
        <*> fields .: "sources"
        <*> fields .: "minimumExcerptLength"
        <*> fields .: "evaluation"
        <*> fields .: "evaluationsPerWindow"
        <*> fields .: "proposalsPerWindow"
        <*> fields .: "notificationsPerWindow"
        <*> fields .: "window"
        <*> fields .: "proposalExpiry"
        <*> fields .: "rejectionSuppression"
        <*> fields .: "notices"
    positive allowance.window
    positive allowance.proposalExpiry
    positive allowance.rejectionSuppression
    pure allowance
    where
      accepted =
        [ "principal",
          "sources",
          "minimumExcerptLength",
          "evaluation",
          "evaluationsPerWindow",
          "proposalsPerWindow",
          "notificationsPerWindow",
          "window",
          "proposalExpiry",
          "rejectionSuppression",
          "notices"
        ]

-- | The operator's spelling of a limit map: a dimension name to a positive
-- amount or the word @unbounded@. Absence remains denial. The root's own stored
-- codec stays what it is; this one exists so a person can write a document.
renderLimits :: Limits -> Value
renderLimits limits = object [Key.fromText (Text.pack (show dimension)) .= renderLimit limit | (dimension, limit) <- Map.toList limits]
  where
    renderLimit = \case
      Limited amount -> toJSON amount
      ExplicitlyUnbounded -> toJSON ("unbounded" :: Text)

parseLimits :: Value -> Parser Limits
parseLimits = withObject "resource limits" \fields ->
  Map.fromList <$> traverse parseEntry (KeyMap.toList fields)
  where
    parseEntry (name, value) = case lookup (Key.toText name) dimensions of
      Nothing -> fail "unknown resource dimension"
      Just dimension -> (dimension,) <$> parseLimit value
    parseLimit = \case
      String "unbounded" -> pure ExplicitlyUnbounded
      value -> Limited <$> parseJSON value
    dimensions = [(Text.pack (show dimension), dimension) | dimension <- [minBound .. maxBound]]

instance ToJSON EvaluationEnvelope where
  toJSON envelope = object ["limits" .= renderLimits envelope.limits, "cutoff" .= envelope.cutoff]

-- | One evaluation is one model call. An envelope that cannot pay for one is a
-- configuration error rather than a refusal every message would silently take:
-- a model attempt charges active work and a model attempt, and the root admits it
-- only when token and cost usage are named. No request ceiling can be reserved
-- for cost before a call, so a finite cost limit could never admit one either.
instance FromJSON EvaluationEnvelope where
  parseJSON = withObject "evaluation envelope" \fields -> do
    unless (all (`elem` ["limits", "cutoff"]) (KeyMap.keys fields)) (fail "unknown evaluation envelope setting")
    limits <- fields .: "limits" >>= parseLimits
    cutoff <- fields .: "cutoff"
    positive cutoff
    unless (all (`Map.member` limits) [ActiveWork, ModelAttempts, Tokens, CostMicroUsd]) (fail "an evaluation envelope must name ActiveWork, ModelAttempts, Tokens and CostMicroUsd")
    unless (Map.lookup CostMicroUsd limits == Just ExplicitlyUnbounded) (fail "an evaluation envelope's CostMicroUsd must be unbounded: no ceiling can be reserved before a call")
    pure EvaluationEnvelope {limits, cutoff}

instance ToJSON NoticeTarget where
  toJSON (KizashiRecipient recipient) = object ["kizashiRecipient" .= recipient]

instance FromJSON NoticeTarget where
  parseJSON = withObject "notice target" \fields -> do
    unless (KeyMap.keys fields == ["kizashiRecipient"]) (fail "unknown notice target")
    KizashiRecipient <$> fields .: "kizashiRecipient"

-- | The one lookup the stream consumer and the Flow share. Observer allowances
-- never admit an unresolved identity.
resolveAllowance :: InitiativeSettings -> AgentIdentity -> Either SkipReason ObserverAllowance
resolveAllowance settings identity = case identityText identity of
  Left (_ :: Text) -> Left NoObserverAllowance
  Right rendered -> maybe (Left NoObserverAllowance) Right (find ((== rendered) . principalText . (.principal)) settings.observers)

-- | A root's cutoff is absolute. It is fixed by the instant the receipt decided on.
evaluationEnvelopeAt :: UTCTime -> EvaluationEnvelope -> Envelope
evaluationEnvelopeAt receivedAt evaluation =
  Envelope {limits = evaluation.limits, cutoff = addUTCTime (durationTime evaluation.cutoff) receivedAt}

allowanceView :: ObserverAllowance -> AllowanceView
allowanceView allowance =
  AllowanceView
    { principal = principalText allowance.principal,
      sources = NonEmpty.toList allowance.sources,
      minimumExcerptLength = initiativeLimitInt allowance.minimumExcerptLength,
      evaluationsPerWindow = initiativeLimitInt allowance.evaluationsPerWindow,
      proposalsPerWindow = initiativeLimitInt allowance.proposalsPerWindow,
      notificationsPerWindow = initiativeLimitInt allowance.notificationsPerWindow,
      windowSeconds = realToFrac (durationTime allowance.window)
    }
