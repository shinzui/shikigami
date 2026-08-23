-- | The narrow bridge from Keiro's durable W3C context to the OTel API.
--
-- Keiro 0.14 publicly captures 'TraceContext', but its generic remote-parent
-- continuation helper is private. This module deliberately consumes Keiro's
-- wire type and the released W3C propagator rather than defining another
-- propagation format.
module Shikigami.Telemetry.TraceContext
  ( withRemoteTraceContext,
    traceHeaders,
  )
where

import Control.Exception (bracket)
import Data.Text.Encoding qualified as Text
import Keiro.Integration.Event (TraceContext (..))
import Network.HTTP.Types.Header (Header)
import OpenTelemetry.Context (insertSpan, removeSpan)
import OpenTelemetry.Context.ThreadLocal (attachContext, detachContext, getContext)
import OpenTelemetry.Propagator.W3CTraceContext (decodeSpanContext)
import OpenTelemetry.Trace.Core (wrapSpanContext)

-- | Run an IO action under the stored remote parent. The Boolean reports
-- whether the traceparent was valid and attached; callers can warn on invalid
-- durable data without failing publication.
withRemoteTraceContext :: TraceContext -> IO a -> IO (Bool, a)
withRemoteTraceContext TraceContext {traceparent, tracestate} action = do
  current <- getContext
  let (continued, attached) =
        case decodeSpanContext (Just (Text.encodeUtf8 traceparent)) (Text.encodeUtf8 <$> tracestate) of
          Nothing -> (False, removeSpan current)
          Just parent -> (True, insertSpan (wrapSpanContext parent) current)
  result <- bracket (attachContext attached) detachContext (const action)
  pure (continued, result)

-- | Render only the W3C propagation headers represented by Keiro's context.
traceHeaders :: TraceContext -> [Header]
traceHeaders TraceContext {traceparent, tracestate} =
  ("traceparent", Text.encodeUtf8 traceparent)
    : maybe [] (pure . ("tracestate",) . Text.encodeUtf8) tracestate
