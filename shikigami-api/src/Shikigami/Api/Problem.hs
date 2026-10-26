{-# LANGUAGE DataKinds #-}
{-# LANGUAGE UndecidableInstances #-}

-- | The one error body the public HTTP API ever returns.
--
-- \"RFC 9457 problem details\" is an IETF standard for describing an HTTP error
-- as a small JSON object instead of an ad-hoc string. It is served under its own
-- media type, @application\/problem+json@, so a client can tell a structured
-- error apart from a successful @application\/json@ payload without inspecting
-- the body.
--
-- This module owns that shape for Shikigami. There is exactly one codec and one
-- schema; no handler, middleware, or error formatter may invent a second error
-- body. The wire keys are exactly @type@, @title@, @status@, @detail@, @code@,
-- and @retryable@ — nothing more, because every additional key becomes a
-- compatibility obligation, and nothing fewer, because clients branch on
-- @code@ and @retryable@.
--
-- Field meanings:
--
--   * @type@ is a URI identifying the problem kind. It stays @\"about:blank\"@
--     until real documentation URIs exist to point at; publishing a URI that
--     404s is worse than publishing none.
--   * @title@ is a short, human-readable summary that is /stable per code/. It
--     never varies with the request, so it can be used as a grouping key in
--     dashboards.
--   * @status@ repeats the HTTP status code in the body, as RFC 9457 requires,
--     for clients that lose the response line through a proxy or log pipeline.
--   * @detail@ is the only per-occurrence text. It must stay free of internal
--     or security-sensitive information: no stack traces, SQL, file paths,
--     credentials, or internal host names.
--   * @code@ is the stable machine-readable identifier clients branch on. Codes
--     are added, never repurposed.
--   * @retryable@ tells a client whether repeating the identical request could
--     succeed. It is derived from the code, not chosen per call site, so the
--     same failure never disagrees with itself between endpoints.
module Shikigami.Api.Problem
  ( -- * The wire body
    ProblemDetails (..),
    problemJsonOptions,

    -- * The problem catalog
    ProblemCode (..),
    problemCodeText,
    problemTitle,
    problemStatus,
    problemRetryable,

    -- * Constructing a problem
    problem,

    -- * Media type
    ProblemJSON,
  )
where

import Data.Aeson (eitherDecode, encode)
import Data.OpenApi (ToSchema (..), fromAesonOptions, genericDeclareNamedSchema)
import Network.HTTP.Media ((//))
import Servant.API (Accept (..), MimeRender (..), MimeUnrender (..))
import Shikigami.Prelude

-- | The RFC 9457 body.
--
-- The first field is spelled 'problemType' rather than @type@ only because
-- @type@ is a Haskell keyword; 'problemJsonOptions' maps it back to the @type@
-- wire key, and that mapping is the sole reason this record deviates from the
-- repository's unprefixed-field rule.
data ProblemDetails = ProblemDetails
  { problemType :: !Text,
    title :: !Text,
    status :: !Int,
    detail :: !Text,
    code :: !Text,
    retryable :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | The single 'Options' value driving both the codec and the published schema,
-- so the document and the bytes on the wire cannot disagree.
problemJsonOptions :: Options
problemJsonOptions =
  defaultOptions
    { fieldLabelModifier = \field -> case field of
        "problemType" -> "type"
        other -> other
    }

instance ToJSON ProblemDetails where
  toJSON = genericToJSON problemJsonOptions

instance FromJSON ProblemDetails where
  parseJSON = genericParseJSON problemJsonOptions

instance ToSchema ProblemDetails where
  declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions problemJsonOptions)

-- | Every problem the public API can report.
--
-- This is a closed catalog on purpose: 'problemCodeText', 'problemTitle',
-- 'problemStatus', and 'problemRetryable' are total over it, so adding a
-- constructor forces a decision about its wire code, its stable title, its
-- status, and whether a retry could help.
data ProblemCode
  = -- | The route matched no resource.
    NotFound
  | AgentNotFound
  | RunNotFound
  | AgentNotRunnable
  | IdempotencyKeyConflict
  | PayloadTooLarge
  | -- | The path exists but not for this HTTP method.
    MethodNotAllowed
  | -- | The request body did not parse or failed validation.
    InvalidBody
  | -- | A path segment or query parameter did not parse into its declared
    -- type. Servant reports both through one formatter and gives no reliable
    -- way to tell them apart, so there is one code rather than two that would
    -- sometimes be wrong.
    InvalidUrl
  | -- | A required header was missing or malformed.
    InvalidHeader
  | -- | Credentials were absent, malformed, or rejected.
    Unauthorized
  | -- | The caller exceeded a rate limit.
    RateLimited
  | -- | An unexpected server-side failure.
    Internal
  | -- | A dependency the request needs is temporarily unavailable.
    Unavailable
  deriving stock (Eq, Show, Generic, Bounded, Enum)

-- | The stable machine-readable identifier. Never change an existing string.
problemCodeText :: ProblemCode -> Text
problemCodeText = \case
  RunNotFound -> "run_not_found"
  AgentNotRunnable -> "agent_not_runnable"
  IdempotencyKeyConflict -> "idempotency_key_conflict"
  PayloadTooLarge -> "payload_too_large"
  AgentNotFound -> "agent_not_found"
  NotFound -> "not_found"
  MethodNotAllowed -> "method_not_allowed"
  InvalidBody -> "invalid_body"
  InvalidUrl -> "invalid_url"
  InvalidHeader -> "invalid_header"
  Unauthorized -> "unauthorized"
  RateLimited -> "rate_limited"
  Internal -> "internal_error"
  Unavailable -> "unavailable"

-- | The stable human-readable summary. Constant per code, never per request.
problemTitle :: ProblemCode -> Text
problemTitle = \case
  RunNotFound -> "Run not found"
  AgentNotRunnable -> "Agent not runnable"
  IdempotencyKeyConflict -> "Idempotency key conflict"
  PayloadTooLarge -> "Payload too large"
  AgentNotFound -> "Agent not found"
  NotFound -> "Resource not found"
  MethodNotAllowed -> "Method not allowed"
  InvalidBody -> "Invalid request body"
  InvalidUrl -> "Invalid request URL"
  InvalidHeader -> "Invalid request header"
  Unauthorized -> "Unauthorized"
  RateLimited -> "Too many requests"
  Internal -> "Internal server error"
  Unavailable -> "Service unavailable"

-- | The HTTP status a code is served with.
problemStatus :: ProblemCode -> Int
problemStatus = \case
  RunNotFound -> 404
  AgentNotRunnable -> 409
  IdempotencyKeyConflict -> 409
  PayloadTooLarge -> 413
  AgentNotFound -> 404
  NotFound -> 404
  MethodNotAllowed -> 405
  InvalidBody -> 400
  InvalidUrl -> 400
  InvalidHeader -> 400
  Unauthorized -> 401
  RateLimited -> 429
  Internal -> 500
  Unavailable -> 503

-- | Whether repeating the identical request could succeed. Derived from the
-- code so two endpoints can never disagree about the same failure.
problemRetryable :: ProblemCode -> Bool
problemRetryable = \case
  RunNotFound -> False
  AgentNotRunnable -> False
  IdempotencyKeyConflict -> False
  PayloadTooLarge -> False
  AgentNotFound -> False
  NotFound -> False
  MethodNotAllowed -> False
  InvalidBody -> False
  InvalidUrl -> False
  InvalidHeader -> False
  Unauthorized -> False
  RateLimited -> True
  Internal -> True
  Unavailable -> True

-- | Build the body for a code, supplying only the per-occurrence @detail@.
--
-- Keep @detail@ free of internal or security-sensitive information; it is the
-- one part of the body that reaches a caller verbatim.
problem :: ProblemCode -> Text -> ProblemDetails
problem problemCode problemDetail =
  ProblemDetails
    { problemType = "about:blank",
      title = problemTitle problemCode,
      status = problemStatus problemCode,
      detail = problemDetail,
      code = problemCodeText problemCode,
      retryable = problemRetryable problemCode
    }

-- | The @application\/problem+json@ media type.
--
-- Declared as its own Servant content type rather than reusing @JSON@ so that a
-- route's type states which alternatives are errors, and so a client can branch
-- on the media type without parsing the body.
data ProblemJSON

instance Accept ProblemJSON where
  contentType _ = "application" // "problem+json"

instance (ToJSON a) => MimeRender ProblemJSON a where
  mimeRender _ = encode

instance (FromJSON a) => MimeUnrender ProblemJSON a where
  mimeUnrender _ = eitherDecode
