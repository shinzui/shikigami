-- | The client owns its command input; it does not link the domain runtime.
module Shikigami.Client.Payload (payloadArgument, readPayload) where

import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.ByteString qualified as Bytes
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Options.Applicative
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr, stdin)

payloadArgument :: Parser (Maybe String)
payloadArgument =
  flag' (Just "-") (long "stdin" <> help "Read a JSON payload object from stdin (up to 4 MiB)")
    <|> optional (strOption (long "payload" <> metavar "JSON|-" <> help "JSON payload object, or - for stdin (default {})"))

readPayload :: Maybe String -> IO Value
readPayload selected = do
  bytes <- case selected of
    Nothing -> pure "{}"
    Just "-" -> Bytes.hGet stdin (4 * 1024 * 1024 + 1)
    Just literal -> pure (Text.encodeUtf8 (Text.pack literal))
  if Bytes.length bytes > 4 * 1024 * 1024
    then refused "payload input exceeds 4 MiB"
    else case eitherDecodeStrict bytes of
      Right value@(Object _) -> pure value
      _ -> refused "payload input must be a JSON object"
  where
    refused message = hPutStrLn stderr message >> exitFailure
