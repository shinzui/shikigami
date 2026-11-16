-- | The journal encoding of a declaration.
--
-- An agent declaration is journaled as JSON when a run ingests it, and a
-- resumed run decodes it again. The golden is the JSON a corpus declaration
-- encoded to when it was pinned. It must keep decoding to the value the
-- declaration loads to today.
module ApiBaseline.Check.JournalCodec
  ( journalCodecFindings,
    encodeGolden,
  )
where

import ApiBaseline.Types (Finding (..), Severity (..))
import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text

-- | The bytes a golden holds: one line of JSON.
encodeGolden :: (ToJSON a) => a -> ByteString
encodeGolden value = LazyByteString.toStrict (Aeson.encode value) <> "\n"

-- | Compare what a declaration loads to with its stored encoding.
journalCodecFindings :: (Eq a, ToJSON a, FromJSON a) => Text -> a -> Maybe ByteString -> [Finding]
journalCodecFindings label loaded = \case
  Nothing -> [Finding Changed (label <> " has no pinned journal encoding")]
  Just golden -> case Aeson.eitherDecodeStrict golden of
    Left problem -> [Finding Breaking (label <> ": the pinned journal encoding no longer decodes:\n" <> Text.pack problem)]
    Right decoded
      | decoded /= loaded -> [Finding Breaking (label <> ": the pinned journal encoding decodes to a different declaration than the file loads to")]
      | encodeGolden loaded /= golden -> [Finding Changed (label <> ": the declaration now encodes to different bytes; the pinned bytes still decode")]
      | otherwise -> []
