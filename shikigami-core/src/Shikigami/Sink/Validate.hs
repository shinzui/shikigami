-- | Declaration errors a manifest can carry that no runtime can fix.
--
-- The rest of this plan makes silently-ignored fields visible at dispatch: a
-- @ReiAction@ with nowhere to send fails into the retry path, and a
-- @recipientFrom@ that could not be answered logs that it fell back. Both are
-- recoverable — configure an endpoint, and the outbox drains; supply a default,
-- and the signal still reaches someone.
--
-- This module covers the case that is not recoverable. A @KizashiSignal@
-- declaring @recipientFrom = SubjectOwner@ or @AreaOwner@ with no
-- @defaultRecipient@ has asked to route by an ownership directory that does not
-- exist and named nobody to fall back to. There is no value the runtime could
-- choose that would be correct, and choosing one anyway is the behavior this
-- MasterPlan exists to remove. So it is refused up front, where the author is
-- looking at the manifest, rather than discovered later from a signal that went
-- to the deployment-wide fallback.
--
-- The check is a pure function over a loaded declaration so that the CLI, the
-- tests, and any future server-side validator all ask the same question.
module Shikigami.Sink.Validate
  ( sinkDeclarationErrors,
    validateKanmonRouteSegment,
  )
where

import Data.Text qualified as Text
import Shikigami.Agent.Decl (AgentDecl (..), RecipientFrom (..), Sink (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Prelude

-- | Every declaration error in an agent's sinks, in declaration order.
--
-- An empty list means the sinks are deployable — not that every field will be
-- honored, which is what the dispatch-time warnings are for.
sinkDeclarationErrors :: AgentDecl -> [Text]
sinkDeclarationErrors AgentDecl {sinks} =
  concatMap sinkErrors sinks

sinkErrors :: Sink -> [Text]
sinkErrors = \case
  KizashiSignal {recipientFrom, defaultRecipient}
    | needsDirectory recipientFrom,
      isNothing defaultRecipient ->
        [ "recipientFrom="
            <> Text.pack (show recipientFrom)
            <> " requires defaultRecipient (no ownership directory exists to resolve it)"
        ]
  ChannelEgress {channel, action, conversationKey} ->
    routeErrors "channel" (declarationCoordinateText channel)
      <> routeErrors "action" (declarationCoordinateText action)
      <> ["conversationKey must be non-empty when declared" | maybe False (Text.null . Text.strip . declarationCoordinateText) conversationKey]
  _ -> []

-- | Validate one path component in Kanmon's channel-action route. The client
-- repeats this check at publication so corrupted durable data cannot inject a
-- slash, query, or traversal-like path after declaration validation has passed.
validateKanmonRouteSegment :: Text -> Either Text Text
validateKanmonRouteSegment segment
  | Text.null segment = Left "must be non-empty"
  | Text.all isAllowed segment = Right segment
  | otherwise = Left "must contain only ASCII letters, digits, '.', '_', or '-'"
  where
    isAllowed char =
      ('a' <= char && char <= 'z')
        || ('A' <= char && char <= 'Z')
        || ('0' <= char && char <= '9')
        || char `elem` ("._-" :: String)

routeErrors :: Text -> Text -> [Text]
routeErrors field value =
  case validateKanmonRouteSegment value of
    Left reason -> [field <> " " <> reason]
    Right _ -> []

-- | Which strategies name a person this platform has no way to look up.
--
-- @Actor@ is absent because it is answerable from the trigger activity; see
-- "Shikigami.Sink.Recipient". If an ownership directory ever exists, the fix is
-- to resolve these two rather than to relax this check.
needsDirectory :: RecipientFrom -> Bool
needsDirectory = \case
  SubjectOwner -> True
  AreaOwner -> True
  Actor -> False
