-- | Implementation details for outbound bearer authentication.
--
-- Keep this module hidden from the package surface. It owns the token
-- constructor and the sole rendering operation so serializable domain types
-- cannot accidentally acquire access to plaintext credentials.
module Shikigami.Sink.Auth.Internal
  ( BearerToken,
    credentialToken,
    packSecretToken,
    bearerTokenFromText,
    matchesBearerHeader,
    renderAuthHeader,
  )
where

import Data.ByteArray (constEq)
import Data.ByteString (ByteString)
import Data.Text.Encoding qualified as Text
import Shikigami.App.Config (SecretText, revealSecretText)
import Shikigami.Pack.Setting (PackSecret, revealPackSecret)
import Shikigami.Prelude (Text)

-- | An opaque bearer credential with no rendering or serialization instances.
newtype BearerToken = BearerToken Text
  deriving stock (Eq)

-- | Convert a resolved secret at the boundary where authentication owns it.
credentialToken :: SecretText -> BearerToken
credentialToken = BearerToken . revealSecretText

-- | The same boundary for a pack's secret setting.
packSecretToken :: PackSecret -> BearerToken
packSecretToken = BearerToken . revealPackSecret

-- | The same boundary for a credential an adapter read from its own source,
-- such as an objective tracker connection's @env:NAME@ reference.
bearerTokenFromText :: Text -> BearerToken
bearerTokenFromText = BearerToken

-- | Compare a received header with the expected bearer header in constant time.
matchesBearerHeader :: BearerToken -> ByteString -> Bool
matchesBearerHeader token received = renderAuthHeader token `constEq` received

-- | Render the header value for the HTTP request builder.
--
-- This function remains internal so no diagnostic or serializable type can
-- turn a 'BearerToken' back into bytes.
renderAuthHeader :: BearerToken -> ByteString
renderAuthHeader (BearerToken token) = "Bearer " <> Text.encodeUtf8 token
