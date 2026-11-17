-- | Running a surface's check and re-pinning it. This is the thin IO around
-- the pure comparisons in "ApiBaseline.Check".
module ApiBaseline.Run
  ( checkSurface,
    pinSurface,
  )
where

import ApiBaseline.Check.CliHelp (cliHelpFindings, goldenName)
import ApiBaseline.Check.DhallSchema (corpusFiles, dhallSchemaFindings, excerpt, loadCorpusFile, semanticHash)
import ApiBaseline.Check.ExportList (exportListFindings, parseInterfaceExports, parsePinned, renderPinned)
import ApiBaseline.Check.ExposedSet (exposedSetFindings, parseExposedSet, renderExposedSet)
import ApiBaseline.Check.JournalCodec (encodeGolden, journalCodecFindings)
import ApiBaseline.Check.KeiroGate (keiroGateFindings)
import ApiBaseline.Check.OpenApi (openApiFindings)
import ApiBaseline.Exposure (parseExposedModules)
import ApiBaseline.Types
import Control.Exception (IOException, try)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Shikigami.Agent.Loader (LoadError (..), loadAgent)
import Shikigami.Api.OpenApi (renderOpenApi, shikigamiOpenApi)
import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory, renameFile)
import System.Exit (ExitCode (..))
import System.FilePath (takeBaseName, takeDirectory, (<.>), (</>))
import System.Process (readProcessWithExitCode)

-- | Run one surface's check from the repository root. @Left@ means the check
-- could not run at all, which is a tool failure and never a clean result.
checkSurface :: Surface -> IO (Either Text [Finding])
checkSurface surface = case surface.check of
  DhallSchema {schema, hash, corpus} -> do
    current <- semanticHash (Text.unpack schema)
    files <- corpusFiles (Text.unpack corpus)
    loads <- mapM (\file -> (file,) <$> loadCorpusFile schema file) files
    pure
      if null files
        then Left ("the corpus " <> corpus <> " holds no declaration, so the schema is checked against nothing")
        else Right (dhallSchemaFindings schema hash current loads)
  JournalCodec {corpus, goldens} -> do
    files <- corpusFiles (Text.unpack corpus)
    findings <-
      mapM
        ( \file ->
            loadAgent file >>= \case
              Left (LoadError problem) -> pure [Finding Breaking (Text.pack file <> " no longer loads:\n" <> excerpt problem)]
              Right declaration -> journalCodecFindings (Text.pack file) declaration <$> readOptional (goldenPath goldens file)
        )
        files
    pure (Right (concat findings))
  OpenApi {frozen} ->
    readOptional (Text.unpack frozen) >>= \case
      Nothing -> pure (Right [Finding Changed ("no frozen copy at " <> frozen)])
      Just bytes -> pure case (Aeson.eitherDecodeStrict bytes, Aeson.eitherDecode currentOpenApi) of
        (Right frozenDocument, Right currentDocument) -> Right (openApiFindings frozenDocument currentDocument)
        (Left problem, _) -> Left ("the frozen copy " <> frozen <> " is not JSON: " <> Text.pack problem)
        (_, Left problem) -> Left ("the current API description is not JSON: " <> Text.pack problem)
  CliHelp {executable, verbs, goldens} ->
    binaryOf executable >>= \case
      Left problem -> pure (Left problem)
      Right binary -> do
        findings <-
          mapM
            ( \verb -> do
                current <- helpText binary verb
                pinned <- fmap decode <$> readOptional (Text.unpack goldens </> goldenName executable verb)
                pure (cliHelpFindings executable verb pinned current)
            )
            verbs
        pure (Right (concat findings))
  ExportList {component, modules, pinned} -> do
    pins <- maybe Map.empty (parsePinned . decode) <$> readOptional (Text.unpack pinned)
    exports <- mapM (interfaceExports component) modules
    pure do
      current <- sequence exports
      Right (concat [exportListFindings moduleName (Map.findWithDefault mempty moduleName pins) names | (moduleName, names) <- zip modules current])
  ExposedSet {cabal, pinned} -> do
    current <- parseExposedModules <$> TextIO.readFile (Text.unpack cabal)
    pins <- maybe mempty (parseExposedSet . decode) <$> readOptional (Text.unpack pinned)
    pure (Right (exposedSetFindings pins current))
  KeiroGate {since} -> do
    ran <- try (readProcessWithExitCode "just" ["keiro-gate", Text.unpack since] "") :: IO (Either IOException (ExitCode, String, String))
    pure case ran of
      Left problem -> Left ("cannot run just keiro-gate: " <> Text.pack (show problem))
      Right (exit, out, err) -> Right (keiroGateFindings (exit == ExitSuccess) (Text.pack (out <> err)))

-- | Rewrite the frozen artifacts of one surface from the working tree, and
-- say which files changed. The inventory's stability and rule are never
-- touched; a schema's pinned hash is the one value rewritten inside it.
pinSurface :: FilePath -> Surface -> IO (Either Text [FilePath])
pinSurface inventory surface = case surface.check of
  DhallSchema {schema, hash} ->
    semanticHash (Text.unpack schema) >>= \case
      Left problem -> pure (Left (schema <> " does not evaluate, so there is nothing to pin:\n" <> problem))
      Right current
        | current == hash -> pure (Right [])
        -- An empty pin cannot be found as text, and replacing the empty
        -- string would rewrite every position of the inventory.
        | Text.null hash -> pure (Left ("the entry's pinned hash is empty; write a placeholder such as \"unpinned\" as its hash and pin again"))
        | otherwise -> do
            contents <- TextIO.readFile inventory
            if hash `Text.isInfixOf` contents
              then do
                -- Write beside it and rename, so a failure never leaves the
                -- inventory truncated.
                let staged = inventory <> ".pinning"
                TextIO.writeFile staged (Text.replace hash current contents)
                renameFile staged inventory
                pure (Right [inventory])
              else pure (Left ("the inventory does not contain the pinned hash " <> hash <> " as text"))
  JournalCodec {corpus, goldens} -> do
    files <- corpusFiles (Text.unpack corpus)
    loaded <- mapM (\file -> fmap (file,) <$> loadAgent file) files
    case sequence loaded of
      Left (LoadError problem) -> pure (Left ("a corpus declaration does not load, so its encoding cannot be pinned:\n" <> problem))
      Right declarations -> Right <$> mapM (\(file, declaration) -> writeBytes (goldenPath goldens file) (encodeGolden declaration)) declarations
  OpenApi {frozen} -> Right . pure <$> writeBytes (Text.unpack frozen) (LazyByteString.toStrict currentOpenApi)
  CliHelp {executable, verbs, goldens} ->
    binaryOf executable >>= \case
      Left problem -> pure (Left problem)
      Right binary ->
        Right
          <$> mapM
            (\verb -> helpText binary verb >>= writeBytes (Text.unpack goldens </> goldenName executable verb) . encode)
            verbs
  ExportList {component, modules, pinned} -> do
    exports <- mapM (interfaceExports component) modules
    case sequence exports of
      Left problem -> pure (Left problem)
      Right current -> Right . pure <$> writeBytes (Text.unpack pinned) (encode (renderPinned (Map.fromList (zip modules current))))
  KeiroGate {} -> pure (Left "the durable wire is pinned by its `since` commit, which the freeze sets in the inventory")
  ExposedSet {cabal, pinned} -> do
    current <- parseExposedModules <$> TextIO.readFile (Text.unpack cabal)
    Right . pure <$> writeBytes (Text.unpack pinned) (encode (renderExposedSet current))

currentOpenApi :: LazyByteString.ByteString
currentOpenApi = renderOpenApi shikigamiOpenApi

goldenPath :: Text -> FilePath -> FilePath
goldenPath goldens file = Text.unpack goldens </> takeBaseName file <.> "json"

-- | The built executable, located by Cabal. Building is the caller's step, so
-- a check never compiles behind the operator's back.
binaryOf :: Text -> IO (Either Text FilePath)
binaryOf executable = do
  (exit, out, _) <- readProcessWithExitCode "cabal" ["list-bin", "-v0", Text.unpack executable] ""
  let binary = Text.unpack (Text.strip (Text.pack out))
  built <- if exit == ExitSuccess then doesFileExist binary else pure False
  pure if built then Right binary else Left ("the executable " <> executable <> " is not built; run: cabal build " <> executable)

helpText :: FilePath -> [Text] -> IO Text
helpText binary verb = do
  (_, out, err) <- readProcessWithExitCode binary (map Text.unpack verb <> ["--help"]) ""
  pure (Text.pack (out <> err))

-- | The exports of one module of a built component, from its interface file.
interfaceExports :: Text -> Text -> IO (Either Text (Set Text))
interfaceExports component moduleName = do
  candidates <- interfaceFiles
  case candidates of
    [] -> pure (Left ("no interface file for " <> moduleName <> "; run: cabal build " <> component))
    interface : _ -> do
      (exit, out, err) <- readProcessWithExitCode "ghc" ["--show-iface", interface] ""
      pure
        if exit == ExitSuccess
          then Right (parseInterfaceExports (Text.pack out))
          else Left ("ghc --show-iface " <> Text.pack interface <> " failed: " <> Text.pack err)
  where
    relative = Text.unpack (Text.replace "." "/" moduleName) <.> "hi"
    -- @package@ names a main library; @package:library@ a sublibrary, whose
    -- interfaces Cabal writes under the package's @l/<library>/build/<library>@.
    (packageName, library) = case Text.breakOn ":" component of
      (name, "") -> (name, Nothing)
      (name, rest) -> (name, Just (Text.unpack (Text.drop 1 rest)))
    interfaceFiles = do
      let build = "dist-newstyle" </> "build"
      architectures <- listOrEmpty build
      compilers <- concat <$> mapM (\architecture -> map ((build </> architecture) </>) <$> listOrEmpty (build </> architecture)) architectures
      packages <- concat <$> mapM (\compiler -> map (compiler </>) . filter (Text.isPrefixOf (packageName <> "-") . Text.pack) <$> listOrEmpty compiler) compilers
      paths <- concat <$> mapM candidates packages
      filterExisting paths
    -- A main library may only re-export modules compiled in a private
    -- sublibrary (the core's @internal@, EP-11 M3), so its modules are looked
    -- for there too; module names are unique within a package.
    candidates package = case library of
      Just name -> pure [package </> "l" </> name </> "build" </> name </> relative]
      Nothing -> do
        sublibraries <- listOrEmpty (package </> "l")
        -- The sublibraries first: a main library's own build directory may
        -- still hold interfaces from before its modules moved.
        pure ([package </> "l" </> name </> "build" </> name </> relative | name <- sublibraries] <> [package </> "build" </> relative])
    listOrEmpty directory = either (const []) id <$> (try (listDirectory directory) :: IO (Either IOException [FilePath]))
    filterExisting = fmap concat . mapM (\path -> (\exists -> [path | exists]) <$> doesFileExist path)

readOptional :: FilePath -> IO (Maybe ByteString.ByteString)
readOptional path = do
  exists <- doesFileExist path
  if exists then Just <$> ByteString.readFile path else pure Nothing

writeBytes :: FilePath -> ByteString.ByteString -> IO FilePath
writeBytes path bytes = do
  createDirectoryIfMissing True (takeDirectory path)
  ByteString.writeFile path bytes
  pure path

decode :: ByteString.ByteString -> Text
decode = TextEncoding.decodeUtf8Lenient

encode :: Text -> ByteString.ByteString
encode = TextEncoding.encodeUtf8
