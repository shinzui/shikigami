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
  )
where

import Baikai.Content (AssistantContent (AssistantText), TextContent (..))
import Baikai.Context (Context (..), _Context)
import Baikai.Message (user)
import Baikai.Model (Model)
import Baikai.Options (_Options)
import Baikai.Provider.Registry (completeRequest)
import Baikai.Response (Response, flattenAssistantBlocks)
import Data.Aeson (Value, object, (.=))
import Data.Aeson.Text (encodeToLazyText)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Data.Text.Lazy qualified as TL
import Data.Vector qualified as V
import Shikigami.Behavior.Error (RunError (..))
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
-- first user message = the instruction body plus the trigger payload rendered as JSON.
-- Returns the assistant reply as @{"reply": <text>}@.
runSkill :: Model -> SkillDir -> Value -> IO (Either RunError Value)
runSkill model dir payload = do
  manifestE <- loadSkillManifest dir
  case manifestE of
    Left e -> pure (Left e)
    Right manifest -> do
      let ctx =
            _Context
              { systemPrompt = Just (description manifest),
                messages = V.singleton (user (body manifest <> "\n\nTrigger payload: " <> renderPayload payload)),
                tools = V.empty
              }
      resp <- completeRequest model ctx _Options
      pure (Right (object ["reply" .= renderReply resp]))

-- | Compact JSON encoding of the trigger payload, for the user message.
renderPayload :: Value -> Text
renderPayload = TL.toStrict . encodeToLazyText

-- | Pull the first assistant text block out of a response (the stub returns exactly
-- one). Falls back to empty text if the response carried no text block.
renderReply :: Response -> Text
renderReply resp =
  case [txt | AssistantText (TextContent {text = txt}) <- V.toList (flattenAssistantBlocks resp)] of
    (txt : _) -> txt
    [] -> ""
