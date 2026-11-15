-- | The host adapter that finds checkouts for the local-operator tier: it
-- runs @git rev-parse --show-toplevel@, @mori path@ and @mori status --json@.
-- The kernel spawns no process ("Shikigami.PackageArchitectureSpec"), so this
-- lives in @local-host@ with the tier's other host adapters (ADR 0125).
module Shikigami.Workspace.Local.Checkout (processCheckoutResolver) where

import Control.Exception (IOException, try)
import Data.Aeson ((.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Shikigami.Trust.LocalOperator.Approvals (CheckoutResolver (..))
import System.Exit (ExitCode (..))
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode, readProcessWithExitCode)

processCheckoutResolver :: CheckoutResolver
processCheckoutResolver =
  CheckoutResolver
    { toplevelOf = \directory -> do
        result <- try (readProcessWithExitCode "git" ["-C", directory, "rev-parse", "--show-toplevel"] "")
        pure case result of
          Right (ExitSuccess, out, _) | [top] <- lines out -> Right top
          Right (_, _, err) -> Left (Text.strip (Text.pack err))
          Left (problem :: IOException) -> Left ("git is unavailable: " <> Text.pack (show problem)),
      moriPath = \identity -> do
        result <- try (readProcessWithExitCode "mori" ["path", Text.unpack identity] "")
        pure case result of
          Right (ExitSuccess, out, _) | [path] <- lines out -> Right path
          Right (_, _, err) -> Left (Text.strip (Text.pack err))
          Left (problem :: IOException) -> Left ("mori is unavailable: " <> Text.pack (show problem)),
      moriIdentity = \directory -> do
        result <- try (readCreateProcessWithExitCode ((proc "mori" ["status", "--json"]) {cwd = Just directory}) "")
        -- @mori status@ exits non-zero when the project has health issues
        -- but still prints its identity, so the exit code is not the signal.
        pure case result of
          Right (_, out, _) -> parseMaybe projectIdentity =<< Aeson.decodeStrict (Text.Encoding.encodeUtf8 (Text.pack out))
          Left (_ :: IOException) -> Nothing
    }
  where
    projectIdentity = Aeson.withObject "status" \value -> do
      project <- value .: "project"
      namespace <- project .: "namespace"
      name <- project .: "name"
      pure ("mori://" <> namespace <> "/" <> name :: Text)
