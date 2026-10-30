-- | Explicit, bounded JSON input for agent command-line entry points.
module Shikigami.Agent.Payload (payloadArgument, readPayloadArgument) where

import Data.ByteString qualified as Bytes
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Options.Applicative
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr, stdin)

payloadArgument :: Parser (Maybe String)
payloadArgument =
  flag' (Just "-") (long "stdin" <> help "Read JSON payload from stdin (up to 4 MiB)")
    <|> optional (strOption (long "payload" <> metavar "JSON|-" <> help "JSON payload, or - to read stdin"))

-- Explicit literal arguments win without touching stdin; omission keeps each
-- command's existing null/object default. No editor, picker or ambient input.
readPayloadArgument :: Maybe String -> IO (Maybe String)
readPayloadArgument (Just "-") = do
  bytes <- Bytes.hGet stdin (4 * 1024 * 1024 + 1)
  if Bytes.length bytes > 4 * 1024 * 1024
    then refused "payload input exceeds 4 MiB"
    else case Text.decodeUtf8' bytes of
      Left _ -> refused "payload input must be UTF-8 JSON"
      Right value -> pure (Just (Text.unpack value))
  where
    refused message = hPutStrLn stderr message >> exitFailure
readPayloadArgument literal = pure literal
