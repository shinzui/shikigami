-- | Bounded JSON-over-HTTP for outbound sink clients.
--
-- A process constructs one 'Manager' and shares it through 'HttpEnv'. Requests
-- are authenticated only from the opaque 'TokenSource', redirects are disabled,
-- and both directions are bounded independently of the response timeout.
module Shikigami.Sink.Http
  ( HttpLimits (..),
    HttpEnv (..),
    SinkCredentials (..),
    SinkHttp (..),
    SinkHttpError (..),
    HttpFailure (..),
    HttpFailureReason (..),
    newSinkManager,
    credentialsFromConfig,
    newSinkHttp,
    unauthenticatedHttpEnv,
    classifyDanwaClientError,
    runDanwaClient,
    runDanwaClientWithHeaders,
    httpFailureIsPermanent,
    renderHttpFailure,
    postJSONWithHeaders,
    postJSON,
  )
where

import Control.Exception (Exception, SomeAsyncException, SomeException, fromException, throwIO, try)
import Control.Monad ((>=>))
import Data.Aeson (encode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Network.HTTP.Client
  ( BodyReader,
    Manager,
    ManagerSettings (managerModifyRequest, managerModifyResponse, managerResponseTimeout),
    Request,
    RequestBody (..),
    Response,
    brRead,
    checkResponse,
    method,
    newManager,
    parseRequest,
    redirectCount,
    requestBody,
    requestHeaders,
    responseBody,
    responseStatus,
    responseTimeoutMicro,
    withResponse,
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Header (Header, hAuthorization, hContentType)
import Network.HTTP.Types.Status (statusCode)
import Servant.Client
  ( BaseUrl,
    ClientEnv (makeClientRequest),
    ClientError (..),
    ClientM,
    ResponseF (responseStatusCode),
    mkClientEnv,
    parseBaseUrl,
    runClientM,
  )
import Shikigami.App.Config
  ( AppConfig (..),
    ByteLimit,
    byteLimitBytes,
  )
import Shikigami.Prelude
import Shikigami.Sink.Auth (CredentialFailure, TokenSource (..), credentialToken, staticTokenSource)
import Shikigami.Sink.Auth.Internal (renderAuthHeader)
import Shikigami.Sink.Config (DanwaConfig (..))

-- | Independent encoded-request and streamed-response bounds.
data HttpLimits = HttpLimits
  { requestBytes :: !ByteLimit,
    responseBytes :: !ByteLimit
  }
  deriving stock (Generic, Eq)

-- | The process-lifetime resources and policy for one HTTP sink.
data HttpEnv = HttpEnv
  { manager :: !Manager,
    token :: !(Maybe TokenSource),
    limits :: !HttpLimits
  }

-- | Per-sink credentials resolved at the process composition root.
data SinkCredentials = SinkCredentials
  { kawa :: !(Maybe TokenSource),
    kizashi :: !(Maybe TokenSource),
    danwa :: !(Maybe TokenSource)
  }
  deriving stock (Generic)

-- | Process-lifetime HTTP clients. Kawa and kizashi share a manager but keep
-- separate token sources; danwa owns a dedicated manager behind its 'ClientEnv'
-- so its request hook cannot authenticate another host.
data SinkHttp = SinkHttp
  { kawa :: !HttpEnv,
    kizashi :: !HttpEnv,
    danwa :: !ClientEnv
  }
  deriving stock (Generic)

-- | Safe startup failures while constructing process-lifetime clients.
data SinkHttpError = InvalidDanwaBaseUrl
  deriving stock (Generic, Eq, Show)

-- | Whether retrying the same request may plausibly repair the failure.
data HttpFailure
  = PermanentHttpFailure !HttpFailureReason
  | TransientHttpFailure !HttpFailureReason
  deriving stock (Eq)

-- | Safe failure facts. No exception text, header value, or response body is
-- retained because any of them may contain a credential or remote-controlled
-- data.
data HttpFailureReason
  = InvalidUrl
  | CredentialUnavailable !CredentialFailure
  | RequestTooLarge !Integer !ByteLimit
  | ResponseTooLarge !ByteLimit
  | UnexpectedStatus !Int
  | InvalidResponse
  | RequestSizeUnknown
  | TransportFailure
  deriving stock (Eq)

instance Show HttpFailure where
  show = Text.unpack . renderHttpFailure

instance Show HttpFailureReason where
  show = Text.unpack . renderHttpFailureReason

-- | Construct the shared TLS-capable manager with a 30-second response timeout.
newSinkManager :: IO Manager
newSinkManager =
  newManager
    tlsManagerSettings
      { managerResponseTimeout = responseTimeoutMicro 30_000_000
      }

-- | Convert redacted Settei values to static opaque sources without exposing
-- their plaintext to any serializable sink configuration.
credentialsFromConfig :: AppConfig -> SinkCredentials
credentialsFromConfig AppConfig {kawaToken = configKawa, kizashiToken = configKizashi, danwaToken = configDanwa} =
  SinkCredentials
    { kawa = sourceFromSecret configKawa,
      kizashi = sourceFromSecret configKizashi,
      danwa = sourceFromSecret configDanwa
    }
  where
    sourceFromSecret = fmap (staticTokenSource . credentialToken)

-- | Build all sink HTTP clients once, before a worker starts consuming work.
newSinkHttp :: HttpLimits -> SinkCredentials -> DanwaConfig -> IO (Either SinkHttpError SinkHttp)
newSinkHttp httpLimits SinkCredentials {kawa = kawaSource, kizashi = kizashiSource, danwa = danwaSource} DanwaConfig {baseUrl} = do
  parsed <- trySynchronous (parseBaseUrl (Text.unpack baseUrl)) :: IO (Either SomeException BaseUrl)
  case parsed of
    Left _ -> pure (Left InvalidDanwaBaseUrl)
    Right danwaBaseUrl -> do
      sharedManager <- newSinkManager
      danwaManager <- newDanwaManager httpLimits danwaSource
      pure
        ( Right
            SinkHttp
              { kawa = HttpEnv {manager = sharedManager, token = kawaSource, limits = httpLimits},
                kizashi = HttpEnv {manager = sharedManager, token = kizashiSource, limits = httpLimits},
                danwa = mkClientEnv danwaManager danwaBaseUrl
              }
        )

-- | Reuse an environment's manager and limits without sending its credential.
unauthenticatedHttpEnv :: HttpEnv -> HttpEnv
unauthenticatedHttpEnv HttpEnv {manager, limits} = HttpEnv {manager, token = Nothing, limits}

-- | Test or map a failure without parsing its rendered prose.
httpFailureIsPermanent :: HttpFailure -> Bool
httpFailureIsPermanent = \case
  PermanentHttpFailure _ -> True
  TransientHttpFailure _ -> False

-- | A bounded, secret-free diagnostic suitable for sink outcomes and logs.
renderHttpFailure :: HttpFailure -> Text
renderHttpFailure = \case
  PermanentHttpFailure reason -> "permanent HTTP failure: " <> renderHttpFailureReason reason
  TransientHttpFailure reason -> "transient HTTP failure: " <> renderHttpFailureReason reason

renderHttpFailureReason :: HttpFailureReason -> Text
renderHttpFailureReason = \case
  InvalidUrl -> "invalid URL"
  CredentialUnavailable failure -> "credential unavailable: " <> Text.pack (show failure)
  RequestTooLarge actual limit ->
    "request body is "
      <> Text.pack (show actual)
      <> " bytes; limit is "
      <> Text.pack (show (byteLimitBytes limit))
  ResponseTooLarge limit ->
    "response body exceeds " <> Text.pack (show (byteLimitBytes limit)) <> " bytes"
  UnexpectedStatus code -> "unexpected status " <> Text.pack (show code)
  InvalidResponse -> "invalid response"
  RequestSizeUnknown -> "request body size is unknown"
  TransportFailure -> "transport error"

-- | POST one encoded JSON value with additional non-authentication headers.
--
-- Caller headers cannot replace @content-type@ or @authorization@. A configured
-- credential source fails closed before URL parsing or network IO. All remote
-- exceptions collapse to a stable transport category.
postJSONWithHeaders :: (ToJSON a) => HttpEnv -> [Header] -> Text -> a -> IO (Either HttpFailure LBS.ByteString)
postJSONWithHeaders env extraHeaders url body = do
  let encoded = encode body
      requestLimit = requestBytes (limits env)
      actualBytes = toInteger (LBS.length encoded)
  if actualBytes > toInteger (byteLimitBytes requestLimit)
    then pure (Left (PermanentHttpFailure (RequestTooLarge actualBytes requestLimit)))
    else
      resolveHeaders (token env) extraHeaders >>= \case
        Left failure -> pure (Left (TransientHttpFailure (CredentialUnavailable failure)))
        Right headers -> do
          parsed <- trySynchronous (parseRequest (Text.unpack url)) :: IO (Either SomeException Request)
          case parsed of
            Left _ -> pure (Left (PermanentHttpFailure InvalidUrl))
            Right request -> execute env encoded headers request

-- | 'postJSONWithHeaders' without caller-supplied headers.
postJSON :: (ToJSON a) => HttpEnv -> Text -> a -> IO (Either HttpFailure LBS.ByteString)
postJSON env = postJSONWithHeaders env []

resolveHeaders :: Maybe TokenSource -> [Header] -> IO (Either CredentialFailure [Header])
resolveHeaders source extraHeaders =
  case source of
    Nothing -> pure (Right baseHeaders)
    Just TokenSource {fetchToken} -> fmap (fmap (\value -> (hAuthorization, renderAuthHeader value) : baseHeaders)) fetchToken
  where
    baseHeaders = (hContentType, "application/json") : filter callerHeaderAllowed extraHeaders

callerHeaderAllowed :: Header -> Bool
callerHeaderAllowed (name, _) = name /= hAuthorization && name /= hContentType

execute :: HttpEnv -> LBS.ByteString -> [Header] -> Request -> IO (Either HttpFailure LBS.ByteString)
execute env encoded headers request = do
  result <-
    trySynchronous
      ( withResponse configured (manager env) \response -> do
          bounded <- readBounded (responseBytes (limits env)) (responseBody response)
          pure case bounded of
            Left failure -> Left failure
            Right responseBytes' -> classifyResponse response responseBytes'
      ) ::
      IO (Either SomeException (Either HttpFailure LBS.ByteString))
  pure case result of
    Left _ -> Left (TransientHttpFailure TransportFailure)
    Right answer -> answer
  where
    configured =
      request
        { method = "POST",
          requestBody = RequestBodyLBS encoded,
          requestHeaders = headers,
          redirectCount = 0,
          checkResponse = \_ _ -> pure ()
        }

classifyResponse :: Response body -> LBS.ByteString -> Either HttpFailure LBS.ByteString
classifyResponse response bytes
  | code >= 200 && code < 300 = Right bytes
  | otherwise = Left (classifyStatus code)
  where
    code = statusCode (responseStatus response)

readBounded :: ByteLimit -> BodyReader -> IO (Either HttpFailure LBS.ByteString)
readBounded limit = go 0 []
  where
    maximumBytes = byteLimitBytes limit

    go total chunks reader = do
      chunk <- brRead reader
      if BS.null chunk
        then pure (Right (LBS.fromChunks (reverse chunks)))
        else do
          let next = total + BS.length chunk
          if next > maximumBytes
            then pure (Left (PermanentHttpFailure (ResponseTooLarge limit)))
            else go next (chunk : chunks) reader

classifyStatus :: Int -> HttpFailure
classifyStatus code
  | code `elem` [408, 425, 429] = TransientHttpFailure (UnexpectedStatus code)
  | code >= 500 && code < 600 = TransientHttpFailure (UnexpectedStatus code)
  | otherwise = PermanentHttpFailure (UnexpectedStatus code)

-- | Convert servant-client failures without retaining its request, response
-- body, arbitrary headers, or exception rendering.
classifyDanwaClientError :: ClientError -> HttpFailure
classifyDanwaClientError = \case
  FailureResponse _ response -> classifyStatus (statusCode (responseStatusCode response))
  DecodeFailure {} -> PermanentHttpFailure InvalidResponse
  UnsupportedContentType {} -> PermanentHttpFailure InvalidResponse
  InvalidContentTypeHeader {} -> PermanentHttpFailure InvalidResponse
  ConnectionError wrapped -> classifyDanwaException wrapped

-- | Run one generated Danwa action while catching both servant errors and the
-- private policy exceptions that manager hooks may throw before http-client has
-- entered its own exception wrapper.
runDanwaClient :: ClientEnv -> ClientM a -> IO (Either HttpFailure a)
runDanwaClient clientEnv action =
  trySynchronous (runClientM action clientEnv) <&> \case
    Left wrapped -> Left (classifyDanwaException wrapped)
    Right (Left failure) -> Left (classifyDanwaClientError failure)
    Right (Right value) -> Right value

-- | Run one generated Danwa action with dispatch-scoped W3C trace headers.
--
-- The 'ClientEnv' override is local to this call, so concurrent deliveries
-- cannot leak context into one another. Only the two W3C propagation headers
-- are accepted; authentication remains owned by the host-scoped manager hook.
runDanwaClientWithHeaders :: [Header] -> ClientEnv -> ClientM a -> IO (Either HttpFailure a)
runDanwaClientWithHeaders extraHeaders clientEnv =
  runDanwaClient
    clientEnv
      { makeClientRequest = \baseUrl request -> do
          outgoing <- makeClientRequest clientEnv baseUrl request
          pure
            outgoing
              { requestHeaders =
                  traceHeaders
                    <> filter ((`notElem` traceHeaderNames) . fst) (requestHeaders outgoing)
              }
      }
  where
    traceHeaders = filter ((`elem` traceHeaderNames) . fst) extraHeaders
    traceHeaderNames = ["traceparent", "tracestate"]

classifyDanwaException :: SomeException -> HttpFailure
classifyDanwaException wrapped =
  case fromException wrapped of
    Just (DanwaCredentialUnavailable failure) -> TransientHttpFailure (CredentialUnavailable failure)
    Just (DanwaRequestTooLarge actual limit) -> PermanentHttpFailure (RequestTooLarge actual limit)
    Just (DanwaResponseTooLarge limit) -> PermanentHttpFailure (ResponseTooLarge limit)
    Just DanwaRequestSizeUnknown -> PermanentHttpFailure RequestSizeUnknown
    Nothing -> TransientHttpFailure TransportFailure

-- | Convert only synchronous failures. Workflow cancellation and process-level
-- asynchronous exceptions must remain able to stop an in-flight sink request.
trySynchronous :: IO value -> IO (Either SomeException value)
trySynchronous action =
  try action >>= \case
    Left failure ->
      case fromException failure :: Maybe SomeAsyncException of
        Just _ -> throwIO failure
        Nothing -> pure (Left failure)
    Right value -> pure (Right value)

data DanwaManagerFailure
  = DanwaCredentialUnavailable !CredentialFailure
  | DanwaRequestTooLarge !Integer !ByteLimit
  | DanwaResponseTooLarge !ByteLimit
  | DanwaRequestSizeUnknown

instance Show DanwaManagerFailure where
  show = \case
    DanwaCredentialUnavailable failure -> "danwa credential unavailable: " <> show failure
    DanwaRequestTooLarge actual limit -> "danwa request is " <> show actual <> " bytes; limit is " <> show (byteLimitBytes limit)
    DanwaResponseTooLarge limit -> "danwa response exceeds " <> show (byteLimitBytes limit) <> " bytes"
    DanwaRequestSizeUnknown -> "danwa request size is unknown"

instance Exception DanwaManagerFailure

newDanwaManager :: HttpLimits -> Maybe TokenSource -> IO Manager
newDanwaManager httpLimits source =
  newManager
    baseSettings
      { managerResponseTimeout = responseTimeoutMicro 30_000_000,
        managerModifyRequest = managerModifyRequest baseSettings >=> configureDanwaRequest httpLimits source,
        managerModifyResponse = managerModifyResponse baseSettings >=> boundDanwaResponse (responseBytes httpLimits)
      }
  where
    baseSettings = tlsManagerSettings

configureDanwaRequest :: HttpLimits -> Maybe TokenSource -> Request -> IO Request
configureDanwaRequest httpLimits source request = do
  checkedBody <- checkDanwaRequestBody (requestBytes httpLimits) (requestBody request)
  headers <- case source of
    Nothing -> pure (filter ((/= hAuthorization) . fst) (requestHeaders request))
    Just TokenSource {fetchToken} ->
      fetchToken >>= \case
        Left failure -> throwIO (DanwaCredentialUnavailable failure)
        Right bearer -> pure ((hAuthorization, renderAuthHeader bearer) : filter ((/= hAuthorization) . fst) (requestHeaders request))
  pure
    request
      { requestBody = checkedBody,
        requestHeaders = headers,
        redirectCount = 0
      }

checkDanwaRequestBody :: ByteLimit -> RequestBody -> IO RequestBody
checkDanwaRequestBody limit body = case body of
  RequestBodyLBS bytes -> checked (toInteger (LBS.length bytes)) body
  RequestBodyBS bytes -> checked (toInteger (BS.length bytes)) body
  RequestBodyBuilder size _ -> checked (toInteger size) body
  RequestBodyStream size _ -> checked (toInteger size) body
  RequestBodyStreamChunked _ -> throwIO DanwaRequestSizeUnknown
  RequestBodyIO build -> build >>= checkDanwaRequestBody limit
  where
    checked actual original
      | actual > toInteger (byteLimitBytes limit) = throwIO (DanwaRequestTooLarge actual limit)
      | otherwise = pure original

boundDanwaResponse :: ByteLimit -> Response BodyReader -> IO (Response BodyReader)
boundDanwaResponse limit response = do
  totalRef <- newIORef 0
  let original = responseBody response
      bounded = do
        chunk <- brRead original
        total <- readIORef totalRef
        let next = total + BS.length chunk
        if next > byteLimitBytes limit
          then throwIO (DanwaResponseTooLarge limit)
          else writeIORef totalRef next >> pure chunk
  pure response {responseBody = bounded}
