-- | The WAI application: route record plus handlers plus error rendering.
--
-- \"WAI\" is Haskell's web-server interface; an @Application@ is the value a web
-- server such as Warp runs. This module turns 'Shikigami.Api.ShikigamiApi' — the
-- type describing what is served — into that value, and is the single place
-- where an error becomes bytes on the wire.
--
-- Servant produces error responses in three ways, and all three are covered here
-- so that a caller never receives a body that is not RFC 9457 problem details:
--
--   1. A handler aborting, which goes through
--      'Shikigami.Server.Seam.throwProblem'.
--   2. A combinator failing to parse the body, URL, or a header, and a request
--      matching no route at all — covered by 'problemErrorFormatters', which
--      Servant looks up in the application 'Context'.
--   3. A path that exists but not for the requested method. Servant answers 405
--      with an empty body and offers no formatter hook for it, so
--      'methodNotAllowedProblem' rewrites that one response in WAI. The rewrite
--      is deliberately narrow: it fires only on status 405 and preserves any
--      headers Servant supplied.
module Shikigami.Server.App
  ( shikigamiApplication,
    shikigamiServer,
    problemErrorFormatters,
    methodNotAllowedProblem,
    exceptionBoundary,
    problemResponse,
  )
where

import Control.Exception (SomeAsyncException, SomeException, catch, fromException, throwIO)
import Data.Aeson (decode, encode)
import Data.ByteString (ByteString)
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.CaseInsensitive qualified as CI
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types (Status (..), hContentLength, hContentType)
import Network.Wai (Application, Middleware, Response, ResponseReceived, pathInfo, responseHeaders, responseLBS, responseStatus)
import Network.Wai.Internal (Response (ResponseBuilder))
import Relay.Pagination.Servant (RelayPageError (..))
import Servant.Health (healthServer)
import Servant.Server
  ( Context (EmptyContext, (:.)),
    ErrorFormatters,
    bodyParserErrorFormatter,
    defaultErrorFormatters,
    headerParseErrorFormatter,
    notFoundErrorFormatter,
    urlParseErrorFormatter,
  )
import Servant.Server.Generic (AsServerT, genericServeTWithContext)
import Shikigami.Agent.Handler (agentServer)
import Shikigami.Api (ShikigamiApi (..))
import Shikigami.Api.Problem (ProblemCode (..), problem, problemStatus, problemTitle)
import Shikigami.App.Config (AppConfig (..))
import Shikigami.Caller.Verifier (newCallerVerifier)
import Shikigami.Prelude
import Shikigami.Server.Seam (ServerEnv (..), ServerM, problemServerError, runServerM)

-- | The application a web server runs.
--
-- Reading outwards: handlers are written in 'ServerM' and brought back to
-- Servant's @Handler@ by 'runServerM'; the 'Context' carries the error
-- formatters; and the 405 rewrite wraps the finished application.
shikigamiApplication :: ServerEnv -> Application
shikigamiApplication env =
  relayPageProblem . methodNotAllowedProblem $
    (genericServeTWithContext (runServerM env) (shikigamiServer env) context)
  where
    context = newCallerVerifier env.logger env.appConfig.httpAuth :. problemErrorFormatters :. EmptyContext

-- | Every handler, assembled against the route record.
--
-- Wiring by field name rather than by position is what stops the classic
-- Servant mistake of connecting two same-typed endpoints to each other's
-- handlers: @live@ and @ready@ have identical types, so only the field names
-- keep them apart.
shikigamiServer :: ServerEnv -> ShikigamiApi (AsServerT ServerM)
shikigamiServer env =
  ShikigamiApi
    { health = healthServer ((.liveness) env) ((.readiness) env),
      agents = agentServer env
    }

-- | Render every Servant-generated parse or routing failure as problem details.
--
-- The parser's own message is deliberately discarded. It can echo the caller's
-- request body — which may hold a secret the caller sent — and it names internal
-- types. Operators get the specifics from structured logs; callers get a stable
-- code they can branch on.
problemErrorFormatters :: ErrorFormatters
problemErrorFormatters =
  defaultErrorFormatters
    { bodyParserErrorFormatter = \_typeRep _request _message ->
        problemServerError InvalidBody "The request body could not be parsed.",
      urlParseErrorFormatter = \_typeRep _request _message ->
        problemServerError InvalidUrl "A path segment or query parameter could not be parsed.",
      headerParseErrorFormatter = \_typeRep _request _message ->
        problemServerError InvalidHeader "A request header was missing or could not be parsed.",
      notFoundErrorFormatter = \_request ->
        problemServerError NotFound "No resource matches the requested path."
    }

-- | Replace Servant's empty 405 body with problem details.
--
-- Narrow on purpose: it inspects only the status, leaves every other response
-- untouched, and keeps any headers Servant produced while replacing the content
-- type and length.
methodNotAllowedProblem :: Middleware
methodNotAllowedProblem app request respond =
  app request \response ->
    if statusCode (responseStatus response) == 405
      then
        respond
          ( problemResponseWith
              (preservedHeaders (responseHeaders response))
              MethodNotAllowed
              "The request method is not supported for this resource."
          )
      else respond response
  where
    preservedHeaders = filter (\(headerName, _) -> headerName /= hContentType && headerName /= hContentLength)

-- | Turn only escaped synchronous failures into the public 500 shape.
--
-- Asynchronous exceptions are process control: request cancellation, Warp
-- shutdown, and executable shutdown must continue unwinding rather than being
-- mislabeled as an application response.
exceptionBoundary :: Middleware
exceptionBoundary app request respond =
  app request respond `catch` handleException
  where
    handleException :: SomeException -> IO ResponseReceived
    handleException exception =
      case fromException exception :: Maybe SomeAsyncException of
        Just _ -> throwIO exception
        Nothing ->
          respond
            ( problemResponse
                Internal
                "The server could not complete the request."
            )

-- | An RFC 9457 response, built the one way error bodies are ever built.
problemResponse :: ProblemCode -> Text -> Response
problemResponse = problemResponseWith []

problemResponseWith :: [(CI.CI ByteString, ByteString)] -> ProblemCode -> Text -> Response
problemResponseWith extraHeaders problemCode problemDetail =
  responseLBS
    (Status (problemStatus problemCode) (TE.encodeUtf8 (problemTitle problemCode)))
    ((hContentType, "application/problem+json") : extraHeaders)
    (encode (problem problemCode problemDetail))

-- | Relay validation happens before handlers and bypasses Servant formatters.
-- Inspect only bounded 400 bodies on the paginated vertical.
relayPageProblem :: Middleware
relayPageProblem app request respond = app request \response ->
  if statusCode (responseStatus response) /= 400
    || take 1 (pathInfo request) /= ["agents"]
    || lookup hContentType (responseHeaders response) == Just "application/problem+json"
    then respond response
    else case response of
      ResponseBuilder _ _ builder ->
        case decode (LBS.take 8192 (toLazyByteString builder)) :: Maybe RelayPageError of
          Just _ -> respond (problemResponse InvalidUrl "The pagination parameters are invalid.")
          Nothing -> respond response
      _ -> respond response
