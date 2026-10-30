{-# OPTIONS_GHC -Wno-orphans #-}

-- | The generated description of the public HTTP API.
--
-- \"OpenAPI\" is a vendor-neutral JSON format for describing an HTTP API:
-- which paths exist, which methods they accept, which status codes and media
-- types they answer with, and the shape of every body. Tools read it to render
-- documentation and to generate clients in other languages.
--
-- The document here is /derived/ from 'Shikigami.Api.shikigamiApi', the same
-- proxy the server serves and the client is generated from. It is never
-- hand-written and never hand-edited: the checked-in artifact at
-- 'openApiArtifactPath' is a build output kept under version control so that
-- changes to the public contract show up in review as a diff.
--
-- Regenerate and check it with:
--
-- > cabal run shikigami-openapi
-- > git diff --exit-code docs/api/openapi.json
--
-- A non-empty diff means the public API changed. That is not a failure to fix by
-- editing the file; it is a contract change to accept deliberately by committing
-- the regenerated artifact.
module Shikigami.Api.OpenApi
  ( shikigamiOpenApi,
    renderOpenApi,
    openApiArtifactPath,
    operationIdFor,
  )
where

import Data.Aeson (Value)
import Data.Aeson.Encode.Pretty (Config (..), Indent (Spaces), encodePretty')
import Data.Aeson.Encode.Pretty qualified as Pretty
import Data.ByteString.Lazy qualified as LBS
import Data.Char qualified as Char
import Data.HashMap.Strict.InsOrd.Compat qualified as InsOrdHashMap
import Data.OpenApi (OpenApi, Operation, PathItem)
import Data.OpenApi qualified as O
import Data.OpenApi.Lens qualified as L
import Data.Text qualified as Text
import Relay.Pagination.Servant.OpenApi ()
import Servant.OpenApi (toOpenApi)
import Shikigami.Api (shikigamiApi)
import Shikigami.Prelude

-- The live document is an opaque JSON value. Keep this third-party orphan at
-- the single generator boundary, including explicit object extension allowance.
instance O.ToSchema Value where
  declareNamedSchema _ = pure (O.NamedSchema (Just "AnyValue") (mempty & L.additionalProperties ?~ O.AdditionalPropertiesAllowed True))

-- | Where the generated artifact lives, relative to the repository root.
openApiArtifactPath :: FilePath
openApiArtifactPath = "docs/api/openapi.json"

-- | The document for everything Shikigami serves.
shikigamiOpenApi :: OpenApi
shikigamiOpenApi =
  withOperationIds (toOpenApi shikigamiApi)
    & L.info
    . L.title
    .~ "Shikigami"
    & L.info
    . L.version
    .~ "0.1.0.0"
    & L.info
    . L.description
    ?~ "The public HTTP API of the Shikigami declared-agent runtime."

-- | Serialize the document the one way the artifact is written.
--
-- Keys are sorted and indentation is fixed so that two runs on the same input
-- produce byte-identical output; otherwise @git diff --exit-code@ would report
-- spurious changes caused by hash ordering.
renderOpenApi :: OpenApi -> LBS.ByteString
renderOpenApi doc = encodePretty' config doc <> "\n"
  where
    config =
      Config
        { confIndent = Spaces 2,
          confCompare = compare,
          confNumFormat = Pretty.Generic,
          confTrailingNewline = False
        }

-- | The stable identifier a client generator uses to name the function for one
-- operation.
--
-- Derived from the method and path so it is deterministic and cannot drift:
-- @GET \/health\/live@ becomes @getHealthLive@. Path parameters contribute their
-- name, so @GET \/agents\/{name}@ becomes @getAgentsByName@ — the @By@ marks the
-- segment as a parameter rather than a literal, which keeps two otherwise
-- identical shapes from colliding.
operationIdFor :: Text -> FilePath -> Text
operationIdFor method path =
  Text.toLower method <> foldMap segmentPart (Text.splitOn "/" (Text.pack path))
  where
    segmentPart segment
      | Text.null segment = ""
      | Just inner <- Text.stripPrefix "{" segment,
        Just name <- Text.stripSuffix "}" inner =
          "By" <> capitalize (sanitize name)
      | otherwise = capitalize (sanitize segment)

    sanitize = Text.concat . fmap capitalize . filter (not . Text.null) . Text.split (not . Char.isAlphaNum)

    capitalize t = case Text.uncons t of
      Nothing -> t
      Just (c, rest) -> Text.cons (Char.toUpper c) rest

-- | Give every operation in the document its deterministic identifier.
withOperationIds :: OpenApi -> OpenApi
withOperationIds = L.paths %~ InsOrdHashMap.mapWithKey assignPath
  where
    assignPath :: FilePath -> PathItem -> PathItem
    assignPath path item =
      item
        & L.get
        %~ withOperationId "get"
        & L.put
        %~ withOperationId "put"
        & L.post
        %~ withOperationId "post"
        & L.delete
        %~ withOperationId "delete"
        & L.options
        %~ withOperationId "options"
        & L.head_
        %~ withOperationId "head"
        & L.patch
        %~ withOperationId "patch"
        & L.trace
        %~ withOperationId "trace"
      where
        withOperationId :: Text -> Maybe Operation -> Maybe Operation
        withOperationId method = fmap (L.operationId ?~ operationIdFor method path)
