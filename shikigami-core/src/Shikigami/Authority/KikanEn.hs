{-# LANGUAGE DataKinds #-}

-- | The Kikan-En adapter of the kernel authority port.
--
-- It maps a kernel 'Action' onto Kikan-En's closed 'AgentAction', asks the
-- Kikan-En service with a Shomei machine token, and returns an allow only
-- after the Kikan client has verified the issued proof locally. An action
-- Kikan-En has no constructor for is refused with 'PolicyDenied'; it is never
-- mapped onto a different Kikan action.
--
-- This module and its children are the only Shikigami modules that import
-- the Kikan-En contract. EP-10 of MasterPlan 22 moves them into the Kikan
-- binding package. Proof and bearer-token bytes never leave this module.
module Shikigami.Authority.KikanEn
  ( KikanEnMapping (..),
    UnmappedAction (..),
    unmappedActionText,
    toAgentAction,
    kikanEnAuthority,
    shomeiClientCredentialsToken,
  )
where

import Data.Aeson ((.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID.V4
import Kikan.En.Action
  ( ActionProblem (..),
    ActionProofError (..),
    AgentAction (..),
    AuthorizeActionError (..),
    AuthorizeActionRequest (..),
    AuthorizedAction (..),
    AutonomyLevel (ActAutonomy),
    Denial (..),
    ShomeiAccessToken,
    actionSchemaHashText,
    actionValueErrorText,
    agentPrincipalText,
    consistencyTokenText,
    mkAgentPrincipal,
    mkAutonomyContext,
    mkCapabilityTarget,
    mkCapabilityToolTarget,
    mkChannelTarget,
    mkDanwaTarget,
    mkIntentionTarget,
    mkKawaTarget,
    mkKizashiTarget,
    mkRequestId,
    mkShomeiAccessToken,
    requestIdText,
  )
import Kikan.En.Action qualified as Kikan
import Kikan.En.Client (KikanEnClient, authorizeAgentAction)
import Servant.Client (ClientEnv)
import Shikigami.Activity.Coordinate (ActivityCoordinate, activityCoordinateText)
import Shikigami.Agent.DeclarationValue (DeclarationCoordinate, declarationCoordinateText)
import Shikigami.Authority hiding (mkCapabilityTarget)
import Shikigami.Behavior.Error (boundedBehaviorDetail)
import Shikigami.Log qualified as Log
import Shomei.Client qualified as Shomei
import Shomei.OAuth.Result (OAuthResult (..), TokenSuccess (..))
import Shomei.Servant.OAuth (TokenResponse (..))

-- | What the adapter adds to a kernel action to name the Kikan-En target.
newtype KikanEnMapping = KikanEnMapping
  { -- | The Kawa source every @kawa.digest@ output of this deployment
    -- publishes to.
    kawaSource :: ActivityCoordinate "source"
  }

data UnmappedAction
  = -- | Kikan-En has no action for this kernel action.
    NoKikanAction !Text
  | -- | The kernel target does not satisfy Kikan-En's target rules.
    InvalidKikanTarget !Text
  deriving stock (Eq, Show)

unmappedActionText :: UnmappedAction -> Text
unmappedActionText = \case
  NoKikanAction detail -> "Kikan-En has no action for " <> detail
  InvalidKikanTarget detail -> detail

-- | The exact Kikan-En action for a kernel action, or why there is none.
toAgentAction :: KikanEnMapping -> UTCTime -> Action -> Either UnmappedAction AgentAction
toAgentAction KikanEnMapping {kawaSource} now = \case
  UseCapability ConnectProvider target ->
    ConnectCapability <$> kikan (mkCapabilityTarget (capabilityTargetId target) (capabilityTargetRevision target))
  UseCapability (InvokeTool tool) target ->
    InvokeCapabilityTool <$> kikan (mkCapabilityToolTarget (capabilityTargetId target) (capabilityTargetRevision target) (toolNameText tool))
  EmitOutput kind target -> case (outputKindText kind, outputTargetSegments target) of
    ("kawa.digest", _) -> DispatchKawa <$> kikan (mkKawaTarget (activityCoordinateText kawaSource))
    ("kizashi.signal", recipient :| []) -> DispatchKizashi <$> kikan (mkKizashiTarget recipient)
    ("rei.action", intention :| []) ->
      (`ActOnIntention` mkAutonomyContext ActAutonomy now) <$> kikan (mkIntentionTarget intention)
    ("danwa.conversation", thread :| []) -> AttachDanwa <$> kikan (mkDanwaTarget thread)
    ("channel.egress", provider :| [conversation]) -> DispatchChannel <$> kikan (mkChannelTarget provider conversation)
    (other, _) -> Left (NoKikanAction ("output kind " <> other <> " with this target"))
  -- Kikan-En has no action for a coding-agent launch yet (MasterPlan 22,
  -- EP-10's improvement request); it is refused, never substituted.
  LaunchCodingAgent {} -> Left (NoKikanAction "a coding-agent launch")
  where
    kikan = either (Left . InvalidKikanTarget . actionValueErrorText) Right

-- | The production adapter. The token source is normally
-- 'shomeiClientCredentialsToken'; keeping it injected permits bounded caching
-- and deterministic tests without weakening proof verification.
kikanEnAuthority ::
  Log.Logger ->
  Text ->
  KikanEnMapping ->
  KikanEnClient ->
  IO (Either Text ShomeiAccessToken) ->
  Authority
kikanEnAuthority logger callerId mapping client tokenSource =
  authority (DecidedByService "kikan-en") \principalCoordinate requested -> do
    now <- getCurrentTime
    case (mkAgentPrincipal (declarationCoordinateText principalCoordinate), toAgentAction mapping now requested) of
      (Left problem, _) -> finish requested (Left (InvalidCoordinates (actionValueErrorText problem))) Nothing
      (_, Left unmapped@NoKikanAction {}) -> finish requested (Left (PolicyDenied (unmappedActionText unmapped))) Nothing
      (_, Left unmapped) -> finish requested (Left (InvalidCoordinates (unmappedActionText unmapped))) Nothing
      (Right principal, Right agentAction) -> do
        requestUuid <- UUID.V4.nextRandom
        case mkRequestId (UUID.toText requestUuid) of
          Left problem -> finish requested (Left (InvalidCoordinates (actionValueErrorText problem))) Nothing
          Right requestId -> do
            let request = AuthorizeActionRequest {principal, action = agentAction, requestId}
            tokenSource >>= \case
              Left detail -> finish requested (Left (AuthorityUnavailable (boundedBehaviorDetail detail))) (Just request)
              Right token -> do
                result <- authorizeAgentAction client token request
                finish requested (firstAuthorizationError requested result) (Just request)
  where
    finish requested result request = do
      logDecision logger callerId requested request result
      pure (fst <$> result)

firstAuthorizationError :: Action -> Either AuthorizeActionError AuthorizedAction -> Either AuthorityFailure (Decision, (Text, Text))
firstAuthorizationError requested = \case
  Left (ActionDenied (Denial problem)) -> Left (PolicyDenied (problemDetail problem))
  Left (ActionRequestInvalid problem) -> Left (InvalidCoordinates (problemDetail problem))
  Left (ActionAuthenticationFailed problem) -> Left (AuthorityUnavailable (problemDetail problem))
  Left (ActionAuthorizationUnavailable problem) -> Left (AuthorityUnavailable (problemDetail problem))
  Left (ActionProofRejected problem) -> Left (ProofRejected (actionProofFailureDetail problem))
  Right AuthorizedAction {requestId, checkedAt, schemaHash, expiresAt} ->
    Right
      ( Decision {action = requested, reference = requestIdText requestId, expiresAt = Just expiresAt},
        (consistencyTokenText checkedAt, actionSchemaHashText schemaHash)
      )

problemDetail :: ActionProblem -> Text
problemDetail ActionProblem {detail} = boundedBehaviorDetail detail

-- Intentionally discard every verifier-supplied detail. Parser and restriction
-- errors are useful to the issuer, but this consumer boundary must never risk
-- retaining input proof bytes in a durable failure outcome.
actionProofFailureDetail :: ActionProofError -> Text
actionProofFailureDetail = \case
  ProofSignatureInvalid {} -> "signature invalid"
  ProofMalformed {} -> "malformed proof"
  ProofExpired -> "expired proof"
  ProofWrongSubject -> "wrong subject"
  ProofWrongAudience -> "wrong audience"
  ProofUnacceptedSchemaHash -> "unaccepted schema hash"
  ProofWrongOperation -> "wrong operation"
  ProofWrongResource -> "wrong resource"
  ProofRevoked -> "revoked proof"
  ProofRestrictionFailed {} -> "restriction failed"
  ProofMetadataMismatch {} -> "response metadata mismatch"

-- | Fetch exactly the machine scope used by Kikan's action endpoint. The
-- client secret is consumed only by Shomei's Basic-auth encoder and is never
-- placed in an error or log value.
shomeiClientCredentialsToken :: ClientEnv -> DeclarationCoordinate "oauth-client" -> Text -> IO (Either Text ShomeiAccessToken)
shomeiClientCredentialsToken env clientId clientSecret =
  Shomei.oauthToken env (declarationCoordinateText clientId) clientSecret ["kikan-en:authorize-agent-action"] >>= \case
    Left _ -> pure (Left "Shomei token transport failed")
    Right (OAuthSuccess TokenSuccess {tokenBody = TokenResponse {accessToken}}) ->
      pure (either (Left . actionValueErrorText) Right (mkShomeiAccessToken accessToken))
    Right OAuthBadRequest {} -> pure (Left "Shomei rejected the client_credentials request")
    Right OAuthAuthenticationFailed {} -> pure (Left "Shomei rejected the machine credential")
    Right OAuthNotFound {} -> pure (Left "Shomei token endpoint was not found")
    Right OAuthInternal {} -> pure (Left "Shomei token service failed")
    Right OAuthUnavailable {} -> pure (Left "Shomei token service is unavailable")

logDecision ::
  Log.Logger ->
  Text ->
  Action ->
  Maybe AuthorizeActionRequest ->
  Either AuthorityFailure (Decision, (Text, Text)) ->
  IO ()
logDecision logger callerId requested request result =
  Log.logInfo
    logger
    "agent_action.authorization"
    ( [ "caller" .= callerId,
        "principal" .= maybe ("invalid" :: Text) (\AuthorizeActionRequest {principal} -> agentPrincipalText principal) request,
        "action" .= maybe (actionTag requested) (\AuthorizeActionRequest {action} -> Kikan.actionTag action) request,
        "resource" .= maybe (actionResource requested) (\AuthorizeActionRequest {action} -> Kikan.canonicalResourceText (Kikan.actionResource action)) request,
        "request_id" .= maybe ("unavailable" :: Text) (\AuthorizeActionRequest {requestId} -> requestIdText requestId) request,
        "decision" .= either authorityFailureLabel (const "allowed") result
      ]
        <> case result of
          Left _ -> []
          Right (Decision {expiresAt}, (checkedAt, schemaHash)) ->
            [ "checked_at" .= checkedAt,
              "schema_hash" .= schemaHash,
              "expires_at" .= fmap (Text.pack . show) expiresAt
            ]
    )
