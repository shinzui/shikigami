module Main (main) where

import Data.ByteString.Lazy qualified as LBS
import Shikigami.Api.OpenApi (openApiArtifactPath, renderOpenApi, shikigamiOpenApi)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

-- | @shikigami-openapi@: regenerate the checked-in description of the public API.
--
-- Run from the repository root:
--
-- > cabal run shikigami-openapi
-- > git diff --exit-code docs/api/openapi.json
--
-- A non-empty diff means the public HTTP contract changed. Commit the
-- regenerated artifact deliberately; never edit it by hand.
main :: IO ()
main = do
  createDirectoryIfMissing True (takeDirectory openApiArtifactPath)
  LBS.writeFile openApiArtifactPath (renderOpenApi shikigamiOpenApi)
  putStrLn ("wrote " <> openApiArtifactPath)
