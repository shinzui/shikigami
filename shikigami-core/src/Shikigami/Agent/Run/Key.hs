-- | Opaque nonempty workflow deduplication coordinates, owned by agent runs.
module Shikigami.Agent.Run.Key
  ( RunKey,
    parseRunKey,
    runKeyText,
    runKeyWithPrefix,
    runKeyFromUUID,
    newCliRunKey,
  )
where

import Data.Aeson (FromJSON (..), ToJSON, object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID.V4
import Shikigami.Agent.Name (AgentName)
import Shikigami.Decision.Contract (versionedDigest)

newtype RunKey = RunKey Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

parseRunKey :: Text -> Either Text RunKey
parseRunKey value
  | Text.null value = Left "run key must not be empty"
  | otherwise = Right (RunKey value)

runKeyText :: RunKey -> Text
runKeyText (RunKey value) = value

-- | A structural nonempty prefix for pure, owner-versioned protocols.
runKeyWithPrefix :: NonEmpty Char -> Text -> RunKey
runKeyWithPrefix prefix suffix = RunKey (Text.pack (NonEmpty.toList prefix) <> suffix)

-- | Capture a canonical native UUID without changing its workflow identity.
runKeyFromUUID :: UUID -> RunKey
runKeyFromUUID = RunKey . UUID.toText

-- | A fresh invocation nonce, not a Kioku session allocation. The queued key
-- retains it across delivery retries through the native workflow protocol.
newCliRunKey :: AgentName -> IO RunKey
newCliRunKey agent = do
  nonce <- UUID.V4.nextRandom
  pure (runKeyWithPrefix ('c' :| "li-run-v2:") (versionedDigest "shikigami.cli-run/2" (object ["agent" .= agent, "nonce" .= UUID.toText nonce])))

instance FromJSON RunKey where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseRunKey
