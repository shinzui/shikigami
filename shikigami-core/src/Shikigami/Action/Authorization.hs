-- | Fail-closed authorization for one concrete external agent action.
--
-- The function seam is intentionally smaller than either Kikan-En or Shomei.
-- Callers submit a verified Meibo principal and a closed Kikan action; a
-- successful result has already passed the Kikan client's local Biscuit
-- verification. Proof and bearer-token bytes never leave this module.
module Shikigami.Action.Authorization
  ( ActionAuthorizer (..),
    ActionAuthorizationFailure (..),
    ActionAuthorizationDecision (..),
    denyAllActionAuthorizer,
    allowAllActionAuthorizerForTests,
    newKikanActionAuthorizer,
    shomeiClientCredentialsToken,
    authorizationFailureDetail,
  )
where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID.V4
import Kikan.En.Action
  ( ActionProblem (..),
    ActionProofError (..),
    AgentAction,
    AuthorizeActionError (..),
    AuthorizeActionRequest (..),
    AuthorizedAction (..),
    Denial (..),
    ShomeiAccessToken,
    actionResource,
    actionSchemaHashText,
    actionTag,
    actionValueErrorText,
    agentPrincipalText,
    canonicalResourceText,
    consistencyTokenText,
    mkAgentPrincipal,
    mkRequestId,
    mkShomeiAccessToken,
    requestIdText,
  )
import Kikan.En.Client (KikanEnClient, authorizeAgentAction)
import Servant.Client (ClientEnv)
import Shikigami.Behavior.Error (boundedBehaviorDetail)
import Shikigami.Log qualified as Log
import Shomei.Client qualified as Shomei
import Shomei.OAuth.Result (OAuthResult (..), TokenSuccess (..))
import Shomei.Servant.OAuth (TokenResponse (..))

data ActionAuthorizationFailure
  = ActionPolicyDenied !Text
  | ActionServiceUnavailable !Text
  | ActionProofVerificationFailed !Text
  | ActionCoordinatesInvalid !Text
  deriving stock (Eq, Show)

-- | Bounded, non-secret coordinates retained after the proof has been checked.
-- The Biscuit is deliberately absent.
data ActionAuthorizationDecision = ActionAuthorizationDecision
  { authorizedAction :: !AgentAction,
    authorizedResource :: !Text,
    authorizationRequestId :: !Text,
    authorizationCheckedAt :: !Text,
    authorizationSchemaHash :: !Text,
    authorizationExpiresAt :: !Text
  }
  deriving stock (Eq, Show)

data ActionAuthorizer = ActionAuthorizer
  { authorize :: Text -> AgentAction -> IO (Either ActionAuthorizationFailure ActionAuthorizationDecision),
    kawaSource :: !Text
  }

-- | Compatibility value for composition roots that have not supplied the C13
-- trust material. It never falls back to C11 or declaration authority.
denyAllActionAuthorizer :: ActionAuthorizer
denyAllActionAuthorizer =
  ActionAuthorizer
    { authorize = \_ _ -> pure (Left (ActionServiceUnavailable "per-action authorization is not configured")),
      kawaSource = "unconfigured"
    }

-- | In-memory fixture for existing focused tests. Production composition roots
-- must use 'newKikanActionAuthorizer' or the fail-closed value above.
allowAllActionAuthorizerForTests :: ActionAuthorizer
allowAllActionAuthorizerForTests =
  ActionAuthorizer
    { authorize = \_ requestedAction ->
        pure
          ( Right
              ActionAuthorizationDecision
                { authorizedAction = requestedAction,
                  authorizedResource = canonicalResourceText (actionResource requestedAction),
                  authorizationRequestId = "request_test",
                  authorizationCheckedAt = "test",
                  authorizationSchemaHash = "sha256:test",
                  authorizationExpiresAt = "test"
                }
          ),
      kawaSource = "shinzui/shikigami"
    }

-- | Production interpreter. The token source is normally
-- 'shomeiClientCredentialsToken'; keeping it injected permits bounded caching
-- and deterministic tests without weakening proof verification.
newKikanActionAuthorizer ::
  Log.Logger ->
  Text ->
  Text ->
  KikanEnClient ->
  IO (Either Text ShomeiAccessToken) ->
  ActionAuthorizer
newKikanActionAuthorizer logger callerId configuredKawaSource client tokenSource =
  ActionAuthorizer
    { kawaSource = configuredKawaSource,
      authorize = \principalText requestedAction -> do
        case mkAgentPrincipal principalText of
          Left problem -> finish (Left (ActionCoordinatesInvalid (actionValueErrorText problem))) Nothing
          Right principal -> do
            requestUuid <- UUID.V4.nextRandom
            case mkRequestId (UUID.toText requestUuid) of
              Left problem -> finish (Left (ActionCoordinatesInvalid (actionValueErrorText problem))) Nothing
              Right requestId -> do
                let request = AuthorizeActionRequest {principal, action = requestedAction, requestId}
                tokenSource >>= \case
                  Left detail -> finish (Left (ActionServiceUnavailable (boundedBehaviorDetail detail))) (Just request)
                  Right token -> do
                    result <- authorizeAgentAction client token request
                    finish (firstAuthorizationError result) (Just request)
    }
  where
    finish result request = do
      logDecision logger callerId request result
      pure result

firstAuthorizationError :: Either AuthorizeActionError AuthorizedAction -> Either ActionAuthorizationFailure ActionAuthorizationDecision
firstAuthorizationError = \case
  Left (ActionDenied (Denial problem)) -> Left (ActionPolicyDenied (problemDetail problem))
  Left (ActionRequestInvalid problem) -> Left (ActionCoordinatesInvalid (problemDetail problem))
  Left (ActionAuthenticationFailed problem) -> Left (ActionServiceUnavailable (problemDetail problem))
  Left (ActionAuthorizationUnavailable problem) -> Left (ActionServiceUnavailable (problemDetail problem))
  Left (ActionProofRejected problem) -> Left (ActionProofVerificationFailed (actionProofFailureDetail problem))
  Right AuthorizedAction {action, resource, requestId, checkedAt, schemaHash, expiresAt} ->
    Right
      ActionAuthorizationDecision
        { authorizedAction = action,
          authorizedResource = canonicalResourceText resource,
          authorizationRequestId = requestIdText requestId,
          authorizationCheckedAt = consistencyTokenText checkedAt,
          authorizationSchemaHash = actionSchemaHashText schemaHash,
          authorizationExpiresAt = Text.pack (show expiresAt)
        }

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

authorizationFailureDetail :: ActionAuthorizationFailure -> Text
authorizationFailureDetail = \case
  ActionPolicyDenied detail -> "denied: " <> boundedBehaviorDetail detail
  ActionServiceUnavailable detail -> "unavailable: " <> boundedBehaviorDetail detail
  ActionProofVerificationFailed detail -> "proof rejected: " <> boundedBehaviorDetail detail
  ActionCoordinatesInvalid detail -> "invalid coordinates: " <> boundedBehaviorDetail detail

-- | Fetch exactly the machine scope used by Kikan's action endpoint. The
-- client secret is consumed only by Shomei's Basic-auth encoder and is never
-- placed in an error or log value.
shomeiClientCredentialsToken :: ClientEnv -> Text -> Text -> IO (Either Text ShomeiAccessToken)
shomeiClientCredentialsToken env clientId clientSecret =
  Shomei.oauthToken env clientId clientSecret ["kikan-en:authorize-agent-action"] >>= \case
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
  Maybe AuthorizeActionRequest ->
  Either ActionAuthorizationFailure ActionAuthorizationDecision ->
  IO ()
logDecision logger callerId request result =
  Log.logInfo
    logger
    "agent_action.authorization"
    ( [ "caller" Aeson..= callerId,
        "principal" Aeson..= maybe ("invalid" :: Text) (\AuthorizeActionRequest {principal} -> agentPrincipalText principal) request,
        "action" Aeson..= maybe ("invalid" :: Text) (\AuthorizeActionRequest {action} -> actionTag action) request,
        "resource" Aeson..= maybe ("invalid" :: Text) (\AuthorizeActionRequest {action} -> canonicalResourceText (actionResource action)) request,
        "request_id" Aeson..= maybe ("unavailable" :: Text) (\AuthorizeActionRequest {requestId} -> requestIdText requestId) request,
        "decision" Aeson..= decisionLabel result
      ]
        <> case result of
          Left _ -> []
          Right ActionAuthorizationDecision {authorizationCheckedAt, authorizationSchemaHash, authorizationExpiresAt} ->
            [ "checked_at" Aeson..= authorizationCheckedAt,
              "schema_hash" Aeson..= authorizationSchemaHash,
              "expires_at" Aeson..= authorizationExpiresAt
            ]
    )
  where
    decisionLabel = \case
      Right _ -> "allowed" :: Text
      Left ActionPolicyDenied {} -> "denied"
      Left ActionServiceUnavailable {} -> "unavailable"
      Left ActionProofVerificationFailed {} -> "proof_rejected"
      Left ActionCoordinatesInvalid {} -> "invalid"
