-- | The generated API description says what is really served.
--
-- Four properties matter, and each has a way of going wrong that compilation
-- does not catch:
--
--   * The checked-in artifact matches what the generator produces now. Without
--     this, @docs\/api\/openapi.json@ silently rots into fiction.
--   * Every route's typed alternatives — each status code, each media type —
--     reach the document. @MultiVerb@ puts them in the type; a missing
--     @HasOpenApi@ instance would quietly drop the non-200 ones.
--   * Operation ids are present, stable, and unique, because client generators
--     name functions after them.
--   * A representative encoded value validates against its own published schema,
--     which is the only check that the schema and the codec agree.
module Shikigami.Api.OpenApiSpec (tests) where

import Data.ByteString.Lazy qualified as LBS
import Data.HashMap.Strict.InsOrd.Compat qualified as InsOrdHashMap
import Data.List (sort)
import Data.Maybe (mapMaybe)
import Data.OpenApi (OpenApi, Operation, PathItem)
import Data.OpenApi qualified as O
import Data.OpenApi.Lens qualified as L
import Data.OpenApi.Schema.Validation (validateToJSON)
import Data.Time (UTCTime (..), fromGregorian)
import Shikigami.Api.OpenApi (openApiArtifactPath, operationIdFor, renderOpenApi, shikigamiOpenApi)
import Shikigami.Api.Problem (ProblemCode (Unavailable), problem)
import Shikigami.Health.Api (ProbeStatus (..))
import Shikigami.Prelude
import System.Directory (doesFileExist)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "OpenAPI document"
    [ testCase "bearer security applies to every domain operation and no probe" do
        shikigamiOpenApi ^. L.components . L.securitySchemes @?= O.SecurityDefinitions (InsOrdHashMap.singleton "bearer" (O.SecurityScheme (O.SecuritySchemeHttp (O.HttpSchemeBearer Nothing)) Nothing))
        mapM_
          ( \(path, operation) -> do
              let protected = path `notElem` healthPaths
              operation ^. L.security @?= (if protected then [O.SecurityRequirement (InsOrdHashMap.singleton "bearer" [])] else [])
              InsOrdHashMap.member 401 (operation ^. L.responses . L.responses) @?= protected
          )
          (documentedOperations shikigamiOpenApi),
      testCase "the checked-in artifact is what the generator produces" do
        artifact <- readArtifact
        let generated = renderOpenApi shikigamiOpenApi
        if artifact == generated
          then pure ()
          else
            assertFailure
              ( "docs/api/openapi.json is stale. Regenerate it with `cabal run shikigami-openapi`"
                  <> " and commit the result.\n--- checked in ---\n"
                  <> show (LBS.length artifact)
                  <> " bytes\n--- generated ---\n"
                  <> show (LBS.length generated)
                  <> " bytes"
              ),
      testCase "the document lists every vertical" $
        sort (documentedPaths shikigamiOpenApi) @?= sort (healthPaths <> agentPaths),
      testCase "every probe route publishes both typed alternatives" $
        mapM_
          ( \(path, operation) -> do
              let statuses = sort (InsOrdHashMap.keys (operation ^. L.responses . L.responses))
              statuses @?= [200, 503]
              mapM_
                ( \status ->
                    case InsOrdHashMap.lookup status (operation ^. L.responses . L.responses) of
                      Nothing -> assertFailure (path <> ": missing response " <> show status)
                      Just _ -> pure ()
                )
                statuses
          )
          (filter (\(path, _) -> path `elem` healthPaths) (documentedOperations shikigamiOpenApi)),
      testCase "every operation has a unique, deterministic id" do
        let ids = mapMaybe (\(_, operation) -> operation ^. L.operationId) (documentedOperations shikigamiOpenApi)
        length ids @?= length (documentedOperations shikigamiOpenApi)
        sort ids @?= sort (dedupe ids)
        sort ids @?= ["getAgents", "getAgentsByAgentName", "getHealthLive", "getHealthReady"],
      testCase "operation ids are derived from method and path" do
        operationIdFor "get" "/health/live" @?= ("getHealthLive" :: Text)
        operationIdFor "get" "/agents/{name}" @?= "getAgentsByName"
        operationIdFor "post" "/" @?= "post",
      testCase "an encoded probe body validates against its published schema" $
        validateToJSON
          ProbeStatus
            { status = "failed",
              check = "database",
              failingSince = Just (UTCTime (fromGregorian 2026 7 31) 0)
            }
          @?= [],
      testCase "an encoded problem body validates against its published schema" $
        validateToJSON (problem Unavailable "The store is not reachable.") @?= []
    ]
  where
    dedupe :: (Eq a) => [a] -> [a]
    dedupe = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

documentedPaths :: OpenApi -> [FilePath]
documentedPaths doc = InsOrdHashMap.keys (doc ^. L.paths)

-- | Every (path, operation) pair in the document, in path order.
documentedOperations :: OpenApi -> [(FilePath, Operation)]
documentedOperations doc =
  [ (path, operation)
  | (path, item) <- InsOrdHashMap.toList (doc ^. L.paths),
    operation <- operationsOfItem item
  ]

operationsOfItem :: PathItem -> [Operation]
operationsOfItem item =
  mapMaybe
    (item ^.)
    [L.get, L.put, L.post, L.delete, L.options, L.head_, L.patch, L.trace]

-- | Read the checked-in artifact regardless of which directory the runner used.
--
-- Cabal runs a test suite with the working directory set to its package, but a
-- developer may equally run the binary from the repository root, so both are
-- tried before failing.
readArtifact :: IO LBS.ByteString
readArtifact = go candidates
  where
    candidates = [openApiArtifactPath, "../" <> openApiArtifactPath]

    go [] =
      assertFailure
        ( "cannot find "
            <> openApiArtifactPath
            <> " from the working directory; tried "
            <> show candidates
        )
    go (candidate : rest) = do
      exists <- doesFileExist candidate
      if exists then LBS.readFile candidate else go rest

healthPaths, agentPaths :: [FilePath]
healthPaths = ["/health/live", "/health/ready"]
agentPaths = ["/agents", "/agents/{agentName}"]
