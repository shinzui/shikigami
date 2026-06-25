module Shikigami.Agent.Skill
  ( SkillError (..),
    validateSkill,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Yaml qualified as Yaml
import Shikigami.Prelude
import System.Directory (doesDirectoryExist, doesFileExist)
import System.FilePath (takeBaseName, (</>))

data SkillError
  = SkillDirMissing FilePath
  | SkillMdMissing FilePath
  | SkillFrontMatterMissing FilePath
  | SkillFrontMatterInvalid Text
  | -- | @SkillNameMismatch expected found@: SKILL.md @name@ does not equal the directory base name.
    SkillNameMismatch !Text !Text
  | SkillDescriptionMissing
  deriving stock (Eq, Show)

-- | Validate a skill directory the way `skills-ref validate` does: the directory
-- exists, SKILL.md exists, its YAML front-matter parses, `name` equals the
-- directory base name, and `description` is present and non-empty.
validateSkill :: FilePath -> IO (Either SkillError ())
validateSkill dir = do
  dirOk <- doesDirectoryExist dir
  if not dirOk
    then pure (Left (SkillDirMissing dir))
    else do
      let mdPath = dir </> "SKILL.md"
      mdOk <- doesFileExist mdPath
      if not mdOk
        then pure (Left (SkillMdMissing mdPath))
        else do
          body <- TIO.readFile mdPath
          pure (validateFrontMatter (Text.pack (takeBaseName dir)) body)

-- | Split off the YAML front-matter (between the leading "---" and the next
-- "---"), parse it, and check name + description.
validateFrontMatter :: Text -> Text -> Either SkillError ()
validateFrontMatter dirBase body =
  case frontMatter body of
    Nothing -> Left (SkillFrontMatterMissing "SKILL.md")
    Just yamlText ->
      case Yaml.decodeEither' (TE.encodeUtf8 yamlText) of
        Left err -> Left (SkillFrontMatterInvalid (Text.pack (show err)))
        Right value -> checkFields dirBase value
  where
    frontMatter t =
      case Text.lines t of
        ("---" : rest) ->
          let (fm, _) = break (== "---") rest
           in Just (Text.unlines fm)
        _ -> Nothing

-- | Read `name`/`description` from the parsed YAML object; `name` must equal the
-- directory base name and `description` must be present and non-empty.
checkFields :: Text -> Value -> Either SkillError ()
checkFields dirBase value =
  let found = fromMaybe "" (lookupText "name" value)
   in if found /= dirBase
        then Left (SkillNameMismatch dirBase found)
        else case lookupText "description" value of
          Just d | not (Text.null (Text.strip d)) -> Right ()
          _ -> Left SkillDescriptionMissing

lookupText :: Text -> Value -> Maybe Text
lookupText k (Object o) =
  case KeyMap.lookup (Key.fromText k) o of
    Just (String s) -> Just s
    _ -> Nothing
lookupText _ _ = Nothing
