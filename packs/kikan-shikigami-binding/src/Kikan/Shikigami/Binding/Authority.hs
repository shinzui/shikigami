{-# LANGUAGE DataKinds #-}

-- | The Kikan-En adapter of the kernel authority port, registered by the
-- Kikan binding under @authorization.actions.mode=kikan@ (plan 135, M2).
--
-- It maps a kernel 'Action' onto Kikan-En's closed 'AgentAction', asks the
-- Kikan-En service with a Shomei machine token, and returns an allow only
-- after the Kikan client has verified the issued proof locally. An action
-- Kikan-En has no constructor for is refused with 'PolicyDenied'; it is never
-- mapped onto a different Kikan action.
--
-- This module is the only Shikigami module that imports the Kikan-En
-- contract. Proof and bearer-token bytes never leave it. Its settings keep
-- the keys and environment variables they had in the kernel, so an existing
-- configuration file works unchanged with the Kikan distribution.
module Kikan.Shikigami.Binding.Authority
  ( -- * The registration
    kikanAuthorityAdapter,
    authoritySettings,
    KikanEnSettings (..),
    loadKikanEnSettings,

    -- * The adapter
    KikanEnMapping (..),
    UnmappedAction (..),
    unmappedActionText,
    toAgentAction,
    kikanEnAuthority,
    shomeiClientCredentialsToken,
  )
where

import Data.Aeson (Value (String), (.=))
import Data.Bifunctor (first)
import Data.Either (isRight)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID.V4
import En.Biscuit.Keys (IssuerKeySet, parseIssuerKeySetText)
import Kikan.En.Action
  ( ActionProblem (..),
    ActionProofError (..),
    ActionSchemaHash,
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
    mkActionSchemaHash,
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
import Kikan.En.Client (KikanEnClient, authorizeAgentAction, newActionProofVerifier, newKikanEnClient)
import Network.HTTP.Client.TLS (newTlsManager)
import Servant.Client (ClientEnv, mkClientEnv, parseBaseUrl)
import Shikigami.Activity.Coordinate (ActivityCoordinate, activityCoordinateText)
import Shikigami.Agent.DeclarationValue (DeclarationCoordinate, declarationCoordinate, declarationCoordinateText)
import Shikigami.Authority hiding (mkCapabilityTarget)
import Shikigami.Authority.Adapter (AuthorityAdapter (..), AuthorityContext (..))
import Shikigami.Behavior.Error (boundedBehaviorDetail)
import Shikigami.Pack.Sdk (Logger, PackSetting (..), PackSettings, SettingShape (..), logInfo, packSettingSecret, packSettingText, revealPackSecret)
import Shomei.Client qualified as Shomei
import Shomei.OAuth.Result (OAuthResult (..), TokenSuccess (..))
import Shomei.Servant.OAuth (TokenResponse (..))

-- ── The registration ────────────────────────────────────────────────────────

-- | The Kikan-En authority, selected by @authorization.actions.mode=kikan@.
kikanAuthorityAdapter :: AuthorityAdapter
kikanAuthorityAdapter = AuthorityAdapter {mode = "kikan", build}
  where
    build AuthorityContext {logger, settings, kawaSource} = case loadKikanEnSettings settings of
      Left problem -> pure (Left problem)
      Right KikanEnSettings {kikanBaseUrl, shomeiBaseUrl, shomeiClientId, shomeiClientSecret, issuerPublicKeys, acceptedSchemaHashes, callerId} ->
        case (parseBaseUrl (Text.unpack kikanBaseUrl), parseBaseUrl (Text.unpack shomeiBaseUrl)) of
          (Right kikanBase, Right shomeiBase) -> do
            manager <- newTlsManager
            let verifier = newActionProofVerifier issuerPublicKeys acceptedSchemaHashes (const (pure False))
                client = newKikanEnClient (mkClientEnv manager kikanBase) verifier
                tokenSource = shomeiClientCredentialsToken (mkClientEnv manager shomeiBase) shomeiClientId shomeiClientSecret
            pure (Right (kikanEnAuthority logger callerId KikanEnMapping {kawaSource} client tokenSource))
          _ -> pure (Left "invalid Kikan-En or Shomei authorization base URL")

-- | What the Kikan-En authority is configured with. The client secret is
-- revealed only here, at the Shomei boundary.
data KikanEnSettings = KikanEnSettings
  { kikanBaseUrl :: !Text,
    shomeiBaseUrl :: !Text,
    shomeiClientId :: !(DeclarationCoordinate "oauth-client"),
    shomeiClientSecret :: !Text,
    issuerPublicKeys :: !IssuerKeySet,
    acceptedSchemaHashes :: !(Set ActionSchemaHash),
    callerId :: !Text
  }

kikanEnBaseUrlKey, shomeiBaseUrlKey, shomeiClientIdKey, shomeiClientSecretKey, issuerPublicKeysKey, schemaHashesKey, callerIdKey :: Text
kikanEnBaseUrlKey = "authorization.actions.kikan_en.base_url"
shomeiBaseUrlKey = "authorization.actions.shomei.base_url"
shomeiClientIdKey = "authorization.actions.shomei.client_id"
shomeiClientSecretKey = "credentials.authorization.actions.shomei.client_secret"
issuerPublicKeysKey = "authorization.actions.en.issuer_public_keys"
schemaHashesKey = "authorization.actions.en.schema_hashes"
callerIdKey = "authorization.actions.caller_id"

-- | The settings the binding declares for the authority. Each is optional to
-- the loader, so a distribution executable that runs without Kikan-En starts;
-- @mode=kikan@ then requires all seven ('loadKikanEnSettings').
authoritySettings :: [PackSetting]
authoritySettings =
  [ text kikanEnBaseUrlKey "SHIKIGAMI_ACTION_KIKAN_EN_BASE_URL" "Base URL of Kikan-En's action authorization service" "an http(s) base URL" baseUrl,
    text shomeiBaseUrlKey "SHIKIGAMI_ACTION_SHOMEI_BASE_URL" "Base URL of the Shomei OAuth2 service" "an http(s) base URL" baseUrl,
    text shomeiClientIdKey "SHIKIGAMI_ACTION_SHOMEI_CLIENT_ID" "Shomei service-account client id used for Kikan authorization" "a non-empty client id" nonEmpty,
    setting SecretTextSetting shomeiClientSecretKey "SHIKIGAMI_ACTION_SHOMEI_CLIENT_SECRET" "Shomei client secret used only at the OAuth2 client_credentials boundary" "a non-empty secret" nonEmpty,
    text issuerPublicKeysKey "SHIKIGAMI_ACTION_EN_ISSUER_PUBLIC_KEYS" "Comma-separated En Biscuit issuer public keys as key-id:hex" "a non-empty key-id:64-hex En Biscuit public-key set" (fmap (const ()) . parseIssuerKeySetText),
    text schemaHashesKey "SHIKIGAMI_ACTION_EN_SCHEMA_HASHES" "Comma-separated accepted Kikan-En action schema hashes" "one or more comma-separated canonical schema hashes" (fmap (const ()) . parseSchemaHashes),
    text callerIdKey "SHIKIGAMI_ACTION_CALLER_ID" "Bounded public caller identity written to action authorization audit logs" "a non-empty caller id" nonEmpty
  ]
  where
    text = setting TextSetting
    setting shape key environment description expectation check =
      PackSetting
        { key,
          environment,
          description,
          expectation,
          shape,
          whenAbsent = Nothing,
          validate = \case
            String value -> first (const expectation) (check value)
            _ -> Left expectation
        }
    nonEmpty value = if Text.null (Text.strip value) then Left () else Right ()
    baseUrl value = if isRight (parseBaseUrl (Text.unpack value)) then Right () else Left ()

parseSchemaHashes :: Text -> Either Text (Set ActionSchemaHash)
parseSchemaHashes value = do
  let pieces = filter (not . Text.null) (Text.strip <$> Text.splitOn "," value)
  hashes <- traverse (first actionValueErrorText . mkActionSchemaHash) pieces
  if null hashes then Left "no schema hash" else Right (Set.fromList hashes)

-- | All seven settings, or the keys that are unset or invalid. Never prints
-- a value.
loadKikanEnSettings :: PackSettings -> Either Text KikanEnSettings
loadKikanEnSettings settings =
  case (fetch kikanEnBaseUrlKey, fetch shomeiBaseUrlKey, fetch shomeiClientIdKey, secret, fetch issuerPublicKeysKey >>= parsed parseIssuerKeySetText, fetch schemaHashesKey >>= parsed parseSchemaHashes, fetch callerIdKey) of
    (Just kikanBaseUrl, Just shomeiBaseUrl, Just clientId, Just shomeiClientSecret, Just issuerPublicKeys, Just acceptedSchemaHashes, Just callerId) ->
      Right KikanEnSettings {kikanBaseUrl, shomeiBaseUrl, shomeiClientId = declarationCoordinate clientId, shomeiClientSecret, issuerPublicKeys, acceptedSchemaHashes, callerId}
    _ ->
      Left
        ( "the Kikan-En authority needs "
            <> Text.intercalate ", " [key | (key, missing) <- presence, missing]
        )
  where
    fetch key = packSettingText key settings
    secret = revealPackSecret <$> packSettingSecret shomeiClientSecretKey settings
    parsed parse = either (const Nothing) Just . parse
    presence =
      [ (kikanEnBaseUrlKey, isNothing (fetch kikanEnBaseUrlKey)),
        (shomeiBaseUrlKey, isNothing (fetch shomeiBaseUrlKey)),
        (shomeiClientIdKey, isNothing (fetch shomeiClientIdKey)),
        (shomeiClientSecretKey, isNothing secret),
        (issuerPublicKeysKey, isNothing (fetch issuerPublicKeysKey >>= parsed parseIssuerKeySetText)),
        (schemaHashesKey, isNothing (fetch schemaHashesKey >>= parsed parseSchemaHashes)),
        (callerIdKey, isNothing (fetch callerIdKey))
      ]

-- ── The adapter ─────────────────────────────────────────────────────────────

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
  Logger ->
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
  Logger ->
  Text ->
  Action ->
  Maybe AuthorizeActionRequest ->
  Either AuthorityFailure (Decision, (Text, Text)) ->
  IO ()
logDecision logger callerId requested request result =
  logInfo
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
