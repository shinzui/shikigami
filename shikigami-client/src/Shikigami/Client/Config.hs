-- | The HTTP client's own lightweight Settei boundary; no server runtime import.
module Shikigami.Client.Config
  ( ClientConfig (..),
    clientConfig,
    environmentBindings,
    serverKey,
    tokenKey,
    resolveClientConfig,
    runClientConfig,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Network.URI (URI (..), URIAuth (..), parseURI)
import Settei
import Settei.Env
import Settei.Optparse (SetteiOptions (..), cliSources, resolutionDiagnostic, schemaDiagnostic)
import Settei.Yaml
import Shikigami.Client (Credential, credentialFor)
import System.Exit (ExitCode (..), exitWith)
import System.IO (stderr)

-- No Show/JSON rendering: the resolved credential remains private to requests.
data ClientConfig = ClientConfig
  { server :: !Text,
    credential :: !Credential
  }

serverKey, tokenKey :: Key
serverKey = validKey "server.base-url"
tokenKey = validKey "http.auth.token"

validKey :: Text -> Key
validKey = either (error . show) id . parseKey

clientConfig :: Config ClientConfig
clientConfig =
  ClientConfig
    <$> required (publicSetting serverKey "HTTP server base URL without credentials" (parsedDecoder "an absolute HTTP(S) URL without credentials, query or fragment" parseServer))
    <*> (credentialFor <$> optional (secretSetting tokenKey "Bearer token sent only to the selected server" textDecoder))
  where
    parseServer value = case parseURI (Text.unpack value) of
      Just URI {uriScheme, uriAuthority = Just URIAuth {uriUserInfo, uriRegName}, uriQuery, uriFragment}
        | uriScheme `elem` ["http:", "https:"] && null uriUserInfo && not (null uriRegName) && null uriQuery && null uriFragment -> Right value
      _ -> Left "invalid server URL"

environmentBindings :: Bindings
environmentBindings =
  either
    (error . Text.unpack . renderEnvErrorsText)
    id
    (bindings [binding (EnvName "SHIKIGAMI_SERVER_URL") serverKey, binding (EnvName "SHIKIGAMI_API_TOKEN") tokenKey])

builtIns :: Source
builtIns = either (error . show) id (sourceFromPairs "built in" BuiltInSource [(serverKey, RawText "http://localhost:8080")])

-- Low to high: built-ins, each YAML file, explicit environment, named flags,
-- each --set occurrence. No action consults ambient environment afterwards.
resolveClientConfig :: SetteiOptions -> [Source] -> [Source] -> Source -> ResolveResult ClientConfig
resolveClientConfig options named files environment =
  resolve
    (defaultResolveOptions {unknownKeyPolicy = RejectUnknownKeys})
    ([builtIns] <> files <> [environment] <> named <> cliSources "arguments" options.overrides)
    clientConfig

runClientConfig :: SetteiOptions -> [Source] -> IO ClientConfig
runClientConfig options named =
  case schemaDiagnostic options.diagnosticMode (describe clientConfig) of
    Just output -> TextIO.putStr output >> exitWith ExitSuccess
    Nothing -> do
      loaded <- traverse readFileSource options.configPaths
      files <- either (stop 3) pure (sequence loaded)
      environment <- readEnvironmentSource environmentBindings
      let result = resolveClientConfig options named files environment
      TextIO.hPutStr stderr (renderWarningsText result.warnings)
      case result.answer of
        Left problems -> do
          TextIO.hPutStr stderr (renderErrorsText problems)
          maybe (pure ()) (TextIO.hPutStr stderr) (resolutionDiagnostic options.diagnosticMode result)
          exitWith (ExitFailure 4)
        Right config -> case resolutionDiagnostic options.diagnosticMode result of
          Just output -> TextIO.putStr output >> exitWith ExitSuccess
          Nothing -> pure config
  where
    readFileSource path = fmap (either (Left . renderYamlErrorsText) Right) (readYamlSource (withYamlSourcePath path (yamlSourceOptions (Text.pack path))) path)
    stop code problem = TextIO.hPutStr stderr problem >> exitWith (ExitFailure code)
