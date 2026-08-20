-- | How this runtime turns a name into the bytes a deterministic id is derived
-- from.
module Shikigami.Id.Name (nameBytes) where

import Data.ByteString qualified as ByteString
import Data.Text.Encoding qualified as Text.Encoding
import Data.Word (Word8)
import Shikigami.Prelude

-- | The bytes of a name, as UUIDv5 hashes them.
--
-- RFC 4122 hashes a name as bytes, and the byte encoding of a text name is
-- UTF-8. Every deterministic id in this repository used to write
-- @fmap (fromIntegral . fromEnum) . Text.unpack@ instead, which truncates each
-- 'Char' to its low byte: @\"caf\\xE9\"@ and @\"caf\\x1E9\"@ hash identically,
-- and so would any two agent, workflow, or message names differing only above
-- U+00FF — including at 'Shikigami.Agent.Delegate.delegatedWorkflowId', which
-- mints a delegated child's workflow id, and at the schedule timer id, which is
-- what makes arming idempotent.
--
-- For ASCII the two encodings agree byte for byte, so no id any checked-in
-- manifest produces moves. Only the currently-colliding non-ASCII names
-- separate, which is the point.
nameBytes :: Text -> [Word8]
nameBytes = ByteString.unpack . Text.Encoding.encodeUtf8
