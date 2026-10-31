-- | Implementation details for outbound bearer authentication.
--
-- Keep this module hidden from the package surface. It owns the token
-- constructor and the sole rendering operation so serializable domain types
-- cannot accidentally acquire access to plaintext credentials.
module Shikigami.Sink.Auth.Internal
  ( BearerToken,
    credentialToken,
    matchesBearerHeader,
    renderAuthHeader,
  )
where

import Data.ByteArray (constEq)
import Data.ByteString (ByteString)
import Data.Text.Encoding qualified as Text
import Shikigami.App.Config (SecretText, revealSecretText)
import Shikigami.Prelude (Text)

-- | An opaque bearer credential with no rendering or serialization instances.
newtype BearerToken = BearerToken Text
  deriving stock (Eq)

-- | Convert a resolved secret at the boundary where authentication owns it.
credentialToken :: SecretText -> BearerToken
credentialToken = BearerToken . revealSecretText

-- | Compare a received header with the expected bearer header in constant time.
matchesBearerHeader :: BearerToken -> ByteString -> Bool
matchesBearerHeader token received = renderAuthHeader token `constEq` received

-- | Render the header value for the HTTP request builder.
--
-- This function remains internal so no diagnostic or serializable type can
-- turn a 'BearerToken' back into bytes.
renderAuthHeader :: BearerToken -> ByteString
renderAuthHeader (BearerToken token) = "Bearer " <> Text.encodeUtf8 token
