-- | Checked accounting-entity fixtures and exact logical operation keys.
-- Entity selectors produce synthetic fixed-timestamp UUIDv7 test data; these
-- deterministic fixtures are never application identity allocators.
module Shikigami.Fixture.ExecutionIdentity (fixtureOperationId, fixtureRootId, fixtureAttemptId, fixtureAllocationId) where

import Data.Aeson (toJSON)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric (readHex)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity

fixtureRootId :: Text -> ExecutionRootId
fixtureRootId = either (error . Text.unpack) id . parseExecutionRootId . fixtureText "shikigami_execution_root"

fixtureAttemptId :: Text -> AttemptId
fixtureAttemptId = either (error . Text.unpack) id . parseAttemptId . fixtureText "shikigami_execution_attempt"

fixtureAllocationId :: Text -> AllocationId
fixtureAllocationId = either (error . Text.unpack) id . parseAllocationId . fixtureText "shikigami_execution_allocation"

fixtureText :: Text -> Text -> Text
fixtureText prefix seed =
  let digest = Text.drop 7 (versionedDigest "shikigami.test-fixture-identity/1" (toJSON seed))
      hexadecimal = "0190000000007" <> Text.take 3 digest <> "8" <> Text.take 15 (Text.drop 3 digest)
   in case readHex (Text.unpack hexadecimal) of
        [(number, "")] -> prefix <> "_" <> Text.pack [Text.index alphabet (fromInteger ((number `div` (32 ^ position)) `mod` 32)) | position <- [25, 24 .. 0 :: Int]]
        _ -> error "invalid synthetic identity fixture digest"
  where
    alphabet = "0123456789abcdefghjkmnpqrstvwxyz"

fixtureOperationId :: Text -> OperationId
fixtureOperationId = either (error . Text.unpack) id . parseOperationId
