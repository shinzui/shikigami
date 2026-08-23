-- | Safe outbound bearer-authentication API.
--
-- Tokens are opaque and deliberately have no 'Show', 'Read', or JSON instances.
-- Callers can obtain one from resolved configuration, install it in a
-- 'TokenSource', or compare an already-received header without rendering the
-- credential themselves.
module Shikigami.Sink.Auth
  ( BearerToken,
    CredentialFailure (..),
    CredentialFailureReason (..),
    TokenSource (..),
    credentialToken,
    staticTokenSource,
    matchesBearerHeader,
  )
where

import Shikigami.App.Config (CredentialRef)
import Shikigami.Prelude (Generic)
import Shikigami.Sink.Auth.Internal (BearerToken, credentialToken, matchesBearerHeader)

-- | A credential could not be obtained without exposing the credential value.
data CredentialFailure = CredentialFailure
  { reference :: !CredentialRef,
    reason :: !CredentialFailureReason
  }
  deriving stock (Generic, Eq, Show)

-- | Stable, non-secret reasons a credential lookup may fail.
data CredentialFailureReason
  = CredentialBackendUnavailable
  | CredentialExpired
  | CredentialRejected
  deriving stock (Generic, Eq, Show)

-- | Where bearer tokens come from.
--
-- Configuration supplies a constant today. A future shomei-backed source can
-- fetch a scoped service token, such as @kawa:ingest@ or @signal:raise@, cache
-- the token and its expiry in an @MVar@, and refresh it ahead of expiry behind
-- this same interface, leaving every sink client unchanged. That implementation
-- belongs in a separate @Shikigami.Sink.Auth.Shomei@ module once scoped service
-- token issuance exists in @mori://shinzui/shomei@ (its current request is IR-2
-- in project-relative @docs/initial-spec.md@; an artifact URI is pending Mori
-- coverage). The raw JWT must remain confined to the internal header renderer.
newtype TokenSource = TokenSource
  { fetchToken :: IO (Either CredentialFailure BearerToken)
  }

-- | A token source that always returns one already-resolved credential.
staticTokenSource :: BearerToken -> TokenSource
staticTokenSource token = TokenSource (pure (Right token))
