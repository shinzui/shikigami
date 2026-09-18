-- | The seam between Shikigami's handler monad and Servant's.
--
-- Servant handlers must eventually run in its own @Handler@ monad. Writing
-- handlers directly in @Handler@ would mean threading every dependency through
-- as an argument, so handlers are written in 'ServerM' — @Handler@ plus
-- read-only access to a 'ServerEnv' — and this module supplies the single
-- transformation ('runServerM') that Servant needs to run them.
--
-- It also owns the one place a domain failure becomes an HTTP response. Every
-- error the API can return goes through 'problemServerError', so the body is
-- always the RFC 9457 shape defined in "Shikigami.Api.Problem", served as
-- @application\/problem+json@. Handlers never construct a @ServerError@
-- directly and never write an error body of their own.
module Shikigami.Server.Seam
  ( -- * Environment
    ServerEnv (..),

    -- * Handler monad
    ServerM (..),
    unServerM,
    runServerM,

    -- * Failures
    problemServerError,
    throwProblem,
  )
where

import Control.Monad.Error.Class (MonadError (..))
import Control.Monad.Reader (MonadReader, ReaderT (..))
import Data.Aeson (encode)
import Data.Text qualified as Text
import OpenTelemetry.Trace.Core (Tracer)
import Servant.Health (ProbeCheck)
import Servant.Server (Handler, ServerError (..))
import Shikigami.Api.Problem (ProblemCode, problem, problemStatus, problemTitle)
import Shikigami.App.Config (AppConfig)
import Shikigami.Prelude
import Shikigami.Server.Config (ServerConfig)

-- | Everything a handler may read.
--
-- Probe checks live here rather than being rebuilt per request because
-- @newFailureTracker@ keeps state: it must be the same action across calls for
-- @failingSince@ to report when a failure began rather than when it was last
-- observed.
data ServerEnv = ServerEnv
  { config :: !ServerConfig,
    appConfig :: !AppConfig,
    tracer :: !Tracer,
    liveness :: !ProbeCheck,
    readiness :: !ProbeCheck
  }

-- | The monad every handler is written in.
newtype ServerM a = ServerM (ReaderT ServerEnv Handler a)
  deriving newtype
    ( Functor,
      Applicative,
      Monad,
      MonadIO,
      MonadReader ServerEnv,
      MonadError ServerError
    )

-- | Explicit public unwrapper; independent of record selector generation.
unServerM :: ServerM a -> ReaderT ServerEnv Handler a
unServerM (ServerM action) = action

-- | The natural transformation Servant needs: run a handler in a fixed
-- environment.
runServerM :: ServerEnv -> ServerM a -> Handler a
runServerM env (ServerM action) = runReaderT action env

-- | Turn a problem code and a per-occurrence detail into the HTTP response.
--
-- This is the total catalog function: the status, the stable title, and the
-- @retryable@ flag all come from the code, so two endpoints reporting the same
-- code cannot disagree. Keep @detail@ free of internal or security-sensitive
-- information — it reaches the caller verbatim.
problemServerError :: ProblemCode -> Text -> ServerError
problemServerError problemCode problemDetail =
  ServerError
    { errHTTPCode = problemStatus problemCode,
      errReasonPhrase = Text.unpack (problemTitle problemCode),
      errBody = encode (problem problemCode problemDetail),
      errHeaders = [("Content-Type", "application/problem+json")]
    }

-- | Abort the current handler with a problem response.
throwProblem :: ProblemCode -> Text -> ServerM a
throwProblem problemCode = throwError . problemServerError problemCode
