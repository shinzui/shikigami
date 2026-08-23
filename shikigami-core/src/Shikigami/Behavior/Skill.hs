-- | The skill arm: load a skill's @SKILL.md@, build a @baikai@ 'Context' from its
-- description (system prompt) and instruction body (user message), run a completion,
-- and render the assistant reply as a JSON value. baikai ships no @SKILL.md@ parser,
-- so the frontmatter split is hand-rolled here. With the stub provider the reply is
-- fixed and the model requests no tools, so a single completion suffices.
module Shikigami.Behavior.Skill
  ( SkillDir (..),
    SkillManifest (..),
    loadSkillManifest,
    runSkill,
    runSkillWith,
  )
where

import Baikai.Content (AssistantContent (..), TextContent (..), ToolCall)
import Baikai.Context (Context (..), appendToolResult, emptyContext)
import Baikai.Error (BaikaiError (..), isRetryable)
import Baikai.Message (AssistantPayload (..), ToolResult, toolResultErrorText, toolResultText, user)
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Provider.Registry (completeRequest)
import Baikai.Response (Response (..), flattenAssistantBlocks, responseError)
import Baikai.StopReason (StopReason (ToolUse))
import Control.Exception (Exception, SomeAsyncException, SomeException, displayException, fromException, throwIO)
import Control.Exception qualified as Exception
import Control.Lens ((&), (.~))
import Data.Aeson (Value, object, (.=))
import Data.Aeson.Text (encodeToLazyText)
import Data.Generics.Labels ()
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Data.Text.Lazy qualified as TL
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import GHC.Generics (Generic)
import Kioku.Api.Types (MemoryRecord (..))
import Shikigami.Behavior.Error (RunError (..), boundedBehaviorDetail)
import Shikigami.Behavior.Input (BehaviorInput (..))
import Shikumi.Error (ShikumiError (..), isTransient)
import Shikumi.LLM (runLLM)
import Shikumi.Tool (ToolRegistry, registryBaikai, registryNames, renderToolError, runToolCall)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

-- | A skill directory (contains @SKILL.md@).
newtype SkillDir = SkillDir FilePath

-- | The parsed @SKILL.md@: required name + description from the YAML frontmatter, plus
-- the Markdown instruction body and any declared allowed-tools.
data SkillManifest = SkillManifest
  { name :: !Text,
    description :: !Text,
    body :: !Text,
    allowedTools :: ![Text]
  }
  deriving stock (Eq, Show)

-- | Read @<dir>/SKILL.md@ and split the frontmatter from the body.
loadSkillManifest :: SkillDir -> IO (Either RunError SkillManifest)
loadSkillManifest (SkillDir dir) = do
  let mdPath = dir </> "SKILL.md"
  exists <- doesFileExist mdPath
  if not exists
    then pure (Left (SkillLoadFailed ("SKILL.md not found at " <> Text.pack mdPath)))
    else do
      body <- TIO.readFile mdPath
      pure (parseManifest body)

-- | Parse the @SKILL.md@ text: frontmatter is the lines between the leading @---@ and
-- the next @---@; the body is everything after. The frontmatter is a flat
-- @key: value@ map (no nested YAML), which is all a skill manifest needs.
parseManifest :: Text -> Either RunError SkillManifest
parseManifest t =
  case Text.lines t of
    ("---" : rest) ->
      let (fm, after) = break (== "---") rest
          fields = mapMaybe parseField fm
          bodyLines = drop 1 after
       in case (lookup "name" fields, lookup "description" fields) of
            (Just n, Just d) ->
              Right
                SkillManifest
                  { name = n,
                    description = d,
                    body = Text.unlines bodyLines,
                    allowedTools = []
                  }
            _ -> Left (SkillLoadFailed "SKILL.md frontmatter missing name or description")
    _ -> Left (SkillLoadFailed "SKILL.md missing frontmatter")
  where
    parseField ln =
      case Text.breakOn ":" ln of
        (k, v)
          | not (Text.null v) -> Just (Text.strip k, Text.strip (Text.drop 1 v))
          | otherwise -> Nothing

-- | Run the skill against the given model: system prompt = the skill description,
-- first user message = the instruction body, the trigger payload rendered as JSON,
-- and the agent's prior learnings when it has any.
-- Returns the assistant reply as @{"reply": <text>}@.
--
-- The 'Options' are the caller's, not this module's. They carry the credential the
-- process resolved (see 'Shikigami.Behavior.Run.BehaviorEnv'), so a run's key
-- source is whatever configuration said and never what a provider handler found
-- in the environment.
runSkill :: Model -> Options -> ToolRegistry -> Int -> SkillDir -> BehaviorInput -> IO (Either RunError Value)
runSkill model options registry turnLimit dir input =
  runSkillWith model options registry turnLimit dir input completeRequest

-- | 'runSkill' with the completion function supplied.
--
-- The seam exists for tracing, and it is also what lets a test observe exactly
-- what would have been sent — including which credential source the options
-- carry — without a key, a network, or a registered provider.
runSkillWith ::
  Model ->
  Options ->
  ToolRegistry ->
  Int ->
  SkillDir ->
  BehaviorInput ->
  (Model -> Context -> Options -> IO Response) ->
  IO (Either RunError Value)
runSkillWith model options registry turnLimit dir BehaviorInput {payload, recalled} complete = do
  manifestE <- loadSkillManifest dir
  case manifestE of
    Left e -> pure (Left e)
    Right manifest -> do
      let ctx =
            emptyContext
              & #systemPrompt .~ Just (description manifest)
              & #messages
                .~ V.singleton
                  ( user
                      ( body manifest
                          <> "\n\nTrigger payload: "
                          <> renderPayload payload
                          <> renderPriorLearnings recalled
                      )
                  )
              & #tools .~ V.empty
      if null (registryNames registry)
        then do
          -- This is deliberately the original one-completion request path.
          resp <- complete model ctx options
          pure (renderResponse resp)
        else
          if turnLimit < 1
            then pure (Left (SkillToolTurnLimitExceeded turnLimit))
            else
              runToolPath
                complete
                model
                options
                registry
                turnLimit
                (ctx & #tools .~ registryBaikai registry)

runToolPath ::
  (Model -> Context -> Options -> IO Response) ->
  Model ->
  Options ->
  ToolRegistry ->
  Int ->
  Context ->
  IO (Either RunError Value)
runToolPath complete model options registry turnLimit = go turnLimit
  where
    go remaining ctx = do
      resp <- complete model ctx options
      case responseError resp of
        Just err -> pure (Left (ProviderFailed (isRetryable err) (renderProviderError err)))
        Nothing
          | responseStopReason resp == ToolUse,
            not (null (responseToolCalls resp)) ->
              if remaining <= 1
                then pure (Left (SkillToolTurnLimitExceeded turnLimit))
                else do
                  advanced <-
                    Exception.try @SkillToolInfrastructureFailure
                      (appendToolResult ctx resp (safeToolDispatcher registry))
                  case advanced of
                    Left (SkillToolInfrastructureFailure infraError) ->
                      pure
                        ( Left
                            ( SkillToolInfrastructureFailed
                                (isTransient infraError)
                                (renderShikumiError infraError)
                            )
                        )
                    Right next -> go (remaining - 1) next
          | otherwise -> pure (renderResponse resp)

responseStopReason :: Response -> StopReason
responseStopReason Response {message = AssistantPayload {stopReason}} = stopReason

responseToolCalls :: Response -> [ToolCall]
responseToolCalls = V.toList . V.mapMaybe toolCallOf . flattenAssistantBlocks
  where
    toolCallOf = \case
      AssistantToolCall toolCall -> Just toolCall
      _ -> Nothing

newtype SkillToolInfrastructureFailure = SkillToolInfrastructureFailure ShikumiError
  deriving stock (Show, Generic)

instance Exception SkillToolInfrastructureFailure

safeToolDispatcher :: ToolRegistry -> ToolCall -> IO ToolResult
safeToolDispatcher registry call = do
  dispatched <- Exception.try @SomeException (dispatchTool registry call)
  case dispatched of
    Right result -> pure result
    Left exception ->
      case fromException exception :: Maybe SkillToolInfrastructureFailure of
        Just failure -> throwIO failure
        Nothing
          | isAsyncException exception -> throwIO exception
          | otherwise ->
              pure
                ( toolResultErrorText
                    (boundedBehaviorDetail (Text.pack (displayException exception)))
                )

dispatchTool :: ToolRegistry -> ToolCall -> IO ToolResult
dispatchTool registry call = do
  outcome <- runEff . runErrorNoCallStack . runLLM $ runToolCall registry call
  case outcome of
    Left infraError -> throwIO (SkillToolInfrastructureFailure infraError)
    Right (Left toolError) -> pure (toolResultErrorText (renderToolError toolError))
    Right (Right output) -> pure (toolResultText output)

isAsyncException :: SomeException -> Bool
isAsyncException exception =
  case fromException exception :: Maybe SomeAsyncException of
    Just _ -> True
    Nothing -> False

renderShikumiError :: ShikumiError -> Text
renderShikumiError =
  boundedBehaviorDetail . \case
    InvalidJSON detail -> "invalid JSON: " <> detail
    MissingField detail -> "missing field: " <> detail
    SchemaMismatch detail -> "schema mismatch: " <> detail
    ValidationFailure detail -> "validation failure: " <> detail
    ProviderFailure detail -> "provider failure: " <> detail
    ContextWindowExceeded detail -> "context window exceeded: " <> detail
    Timeout detail -> "timeout: " <> detail
    BudgetExceeded detail -> "budget exceeded: " <> detail
    CodeExecFailed detail -> "code execution failed: " <> detail

renderResponse :: Response -> Either RunError Value
renderResponse resp =
  -- Baikai reports provider failure in band: an error-shaped response carries
  -- no assistant text, so reading the reply alone would turn an outage into a
  -- successful empty answer.
  case responseError resp of
    Just err -> Left (ProviderFailed (isRetryable err) (renderProviderError err))
    Nothing -> Right (object ["reply" .= renderReply resp])

-- | A loggable one-line rendering of an in-band provider failure: its category,
-- HTTP status when the call was HTTP, and the provider's own detail.
renderProviderError :: BaikaiError -> Text
renderProviderError BaikaiError {category, message, httpStatus} =
  Text.pack (show category)
    <> maybe "" (\status -> " (HTTP " <> Text.pack (show status) <> ")") httpStatus
    <> ": "
    <> message

-- | Compact JSON encoding of the trigger payload, for the user message.
renderPayload :: Value -> Text
renderPayload = TL.toStrict . encodeToLazyText

-- | The recalled-memory section of the user message, or nothing at all when the
-- agent has yet to learn anything.
--
-- An agent with no memories sends byte-identical requests to the ones it sent
-- before memory was injected, so a first run is not paying for a heading that
-- introduces an empty list.
--
-- The one-line memory format is deliberately the same as
-- 'Shikigami.Agent.Run.renderMemoryRecord' and deliberately not a call to it:
-- @Agent.Run@ imports "Shikigami.Behavior.Run", which imports this module, so
-- importing it back would close a cycle. Change both if you change either.
renderPriorLearnings :: [MemoryRecord] -> Text
renderPriorLearnings [] = ""
renderPriorLearnings memories =
  "\n\nPrior learnings (most relevant first):\n"
    <> Text.intercalate "\n" (renderMemory <$> memories)
  where
    renderMemory MemoryRecord {memoryId, memoryType, confidence, content} =
      "- " <> memoryId <> " [" <> memoryType <> "/" <> confidence <> "] " <> content

-- | Pull the first assistant text block out of a response (the stub returns exactly
-- one). Falls back to empty text if the response carried no text block.
renderReply :: Response -> Text
renderReply resp =
  case [txt | AssistantText (TextContent {text = txt}) <- V.toList (flattenAssistantBlocks resp)] of
    (txt : _) -> txt
    [] -> ""
