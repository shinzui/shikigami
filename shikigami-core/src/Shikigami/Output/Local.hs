-- | The local output (EP-8 M2 of MasterPlan 22): @local.report@ writes a
-- run's result to a file the operator reads.
--
-- Configuration: @{"format": "markdown" | "json"}@. The file is
-- @<root>/<agent>/<run-id>-<ordinal>.<md|json>@, written atomically with mode
-- 0600 and bounded at 1 MiB; a larger result is truncated with a marker. The
-- root is the composition's, so a declaration never chooses a directory.
module Shikigami.Output.Local
  ( localReportAdapter,
    localReportKind,
    defaultLocalReport,
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Keiro.Workflow (WorkflowId (..))
import Shikigami.Agent.Name (agentNameText)
import Shikigami.Output
import System.Directory (createDirectoryIfMissing, renameFile)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

localReportKind :: OutputKind
localReportKind = either (error . Text.unpack) id (mkOutputKind "local.report")

-- | The stock default output: a Markdown report.
defaultLocalReport :: OutputDecl
defaultLocalReport = OutputDecl {kind = localReportKind, config = object ["format" .= ("markdown" :: Text)]}

data ReportFormat = Markdown | Json

formatOf :: Value -> Either Text ReportFormat
formatOf = \case
  Object fields -> case KeyMap.lookup "format" fields of
    Nothing -> Right Markdown
    Just (String "markdown") -> Right Markdown
    Just (String "json") -> Right Json
    Just other -> Left ("format must be \"markdown\" or \"json\", not " <> Text.Encoding.decodeUtf8Lenient (LazyByteString.toStrict (Aeson.encode other)))
  _ -> Left "the configuration must be an object"

reportLimit :: Int
reportLimit = 1048576

localReportAdapter :: FilePath -> OutputAdapter
localReportAdapter root =
  inlineOutputAdapter localReportKind (fmap (const ()) . formatOf) \OutputDelivery {run, agent, ordinal, output, result} -> case formatOf output.config of
    Left problem -> pure (Left problem)
    Right format -> do
      let directory = root </> Text.unpack (agentNameText agent)
          extension = case format of Markdown -> "md"; Json -> "json"
          path = directory </> (Text.unpack (Text.replace "/" "_" run.unWorkflowId) <> "-" <> show ordinal <> "." <> extension)
          rendered = case format of
            Markdown -> Text.Encoding.encodeUtf8 (markdownOf (agentNameText agent) run.unWorkflowId result)
            Json -> LazyByteString.toStrict (Aeson.encode result)
          truncated = ByteString.length rendered > reportLimit
          bytes = if truncated then ByteString.take reportLimit rendered <> "\n\n[truncated at 1 MiB]\n" else rendered
      createDirectoryIfMissing True directory
      let staging = path <> ".tmp"
      ByteString.writeFile staging bytes
      setFileMode staging 0o600
      renameFile staging path
      pure
        ( Right
            OutputReceipt
              { kind = outputKindText localReportKind,
                location = Text.pack path,
                detail = Text.pack (show (ByteString.length bytes)) <> " bytes" <> (if truncated then ", truncated" else "")
              }
        )

-- | The reply (or summary) as prose, and the full result as JSON below it.
markdownOf :: Text -> Text -> Value -> Text
markdownOf agent run result =
  "# " <> agent <> "\n\nRun `" <> run <> "`.\n\n" <> prose <> "\n## Result\n\n```json\n" <> Text.Encoding.decodeUtf8Lenient (LazyByteString.toStrict (Aeson.encode result)) <> "\n```\n"
  where
    prose = case result of
      Object fields | Just (String reply) <- KeyMap.lookup "reply" fields <|> KeyMap.lookup "summary" fields -> reply <> "\n"
      _ -> ""
    a <|> b = maybe b Just a
