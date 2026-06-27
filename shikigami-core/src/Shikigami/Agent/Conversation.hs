module Shikigami.Agent.Conversation
  ( ConversationEnv (..),
    ConversationTurnResult (..),
    runConversationTurn,
  )
where

import Data.Bifunctor (first)
import Data.List (find)
import Data.Text qualified as Text
import Effectful (Eff)
import Kioku.App (AppEffects, AppEnv, runAppIO)
import Kioku.Id (SessionId, genSessionId, parseId)
import Kioku.Session qualified as Session
import Kioku.Session.Domain (RecordTurnData (..), StartSessionData (..))
import Kioku.Session.ReadModel (SessionRow (..), TurnRow (..))
import Kiroku.Store.Error (StoreError)
import Shikigami.Agent.Run (renderLearning)
import Shikigami.Api.Agent (AgentDecl (..))
import Shikigami.Behavior.Run (BehaviorEnv, runBehavior)
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Prelude
import Shikigami.Sink.Config (DanwaConfig)
import Shikigami.Sink.Danwa (postReply)
import Shikigami.Sink.Types (DanwaTarget (..))
import Shikigami.Trigger.Danwa (AddressedMessage (..))

data ConversationEnv = ConversationEnv
  { appEnv :: !AppEnv,
    behaviorEnv :: !BehaviorEnv,
    danwa :: !DanwaConfig
  }

data ConversationTurnResult = ConversationTurnResult
  { sessionId :: !SessionId,
    userTurnId :: !Text,
    asstTurnId :: !Text,
    replyMessageId :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

runConversationTurn :: ConversationEnv -> AgentDecl -> AddressedMessage -> IO (Either Text ConversationTurnResult)
runConversationTurn env decl msg@AddressedMessage {conversationId = msgConversationId, messageId = msgMessageId, content = msgContent} = do
  sessionE <- resolveSession env decl msgConversationId
  case sessionE of
    Left err -> pure (Left err)
    Right sid -> do
      turns <- loadTurns env sid
      let userTurnId = "danwa:user:" <> msgMessageId
          userIndex = length turns
      recordE <- recordTurn env sid userTurnId userIndex "user" msgContent
      case recordE of
        Left err -> pure (Left err)
        Right () -> do
          behaviorE <- first (Text.pack . show) <$> runBehavior (behaviorEnv env) decl (toJSON msg)
          case behaviorE of
            Left err -> pure (Left err)
            Right output -> do
              let replyText = renderLearning output
                  asstTurnId = "danwa:assistant:" <> msgMessageId
                  asstIndex = userIndex + 1
              asstE <- recordTurn env sid asstTurnId asstIndex "assistant" replyText
              case asstE of
                Left err -> pure (Left err)
                Right () -> do
                  replyE <-
                    postReply
                      (danwa env)
                      DanwaTarget
                        { conversationId = msgConversationId,
                          parentMessageId = Just msgMessageId
                        }
                      replyText
                  pure $
                    case replyE of
                      Left err -> Left err
                      Right replyMessageId ->
                        Right
                          ConversationTurnResult
                            { sessionId = sid,
                              userTurnId = userTurnId,
                              asstTurnId = asstTurnId,
                              replyMessageId = replyMessageId
                            }

resolveSession :: ConversationEnv -> AgentDecl -> Text -> IO (Either Text SessionId)
resolveSession env decl conversationId = do
  let scope = agentScope (name decl)
  rowsE <- runKioku env (Session.getByScope scope)
  case rowsE of
    Left err -> pure (Left (Text.pack (show err)))
    Right (Left err) -> pure (Left (Text.pack (show err)))
    Right (Right rows) ->
      case find (isRunningConversationSession conversationId) rows of
        Just (SessionRow {sessionId = sidText}) -> pure (first ("parse session id: " <>) (parseId sidText))
        Nothing -> startSession env decl conversationId

isRunningConversationSession :: Text -> SessionRow -> Bool
isRunningConversationSession conversationId (SessionRow {subjectRef = rowSubjectRef, status = rowStatus}) =
  rowSubjectRef == Just conversationId && rowStatus == "running"

startSession :: ConversationEnv -> AgentDecl -> Text -> IO (Either Text SessionId)
startSession env decl conversationId = do
  now <- getCurrentTime
  sid <- genSessionId
  result <-
    runKioku env $
      Session.start
        StartSessionData
          { sessionId = sid,
            agentId = name decl,
            focus = "conversation",
            scope = agentScope (name decl),
            subjectRef = Just conversationId,
            previousSessionId = Nothing,
            parentSessionId = Nothing,
            delegationDepth = 0,
            startedAt = now
          }
  pure case result of
    Left err -> Left (Text.pack (show err))
    Right (Left err) -> Left (Text.pack (show err))
    Right (Right _) -> Right sid

loadTurns :: ConversationEnv -> SessionId -> IO [TurnRow]
loadTurns env sid = do
  result <- runKioku env (Session.getTurns sid)
  pure case result of
    Right (Right turns) -> turns
    _ -> []

recordTurn :: ConversationEnv -> SessionId -> Text -> Int -> Text -> Text -> IO (Either Text ())
recordTurn env sid turnId turnIndex role content = do
  now <- getCurrentTime
  result <-
    runKioku env $
      Session.recordTurn
        RecordTurnData
          { sessionId = sid,
            turnId,
            turnIndex,
            role,
            content,
            toolSummary = Nothing,
            promptTokens = Nothing,
            outputTokens = Nothing,
            recordedAt = now
          }
  pure case result of
    Left err -> Left (Text.pack (show err))
    Right (Left err) -> Left (Text.pack (show err))
    Right (Right _) -> Right ()

runKioku :: ConversationEnv -> Eff AppEffects a -> IO (Either StoreError a)
runKioku env action = runAppIO (appEnv env) action
