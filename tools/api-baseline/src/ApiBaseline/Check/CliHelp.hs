-- | A command line against the @--help@ text it had when pinned.
--
-- Scripts and muscle memory depend on option and subcommand names, so a name
-- that disappears is breaking. Any other difference in the text, such as a
-- reworded description or a new option, is a change to review and re-pin.
module ApiBaseline.Check.CliHelp
  ( cliHelpFindings,
    helpVocabulary,
    goldenName,
  )
where

import ApiBaseline.Types (Finding (..), Severity (..))
import Data.Char (isAlphaNum)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text

-- | The findings for one verb: its pinned help text, if any, and its current text.
cliHelpFindings :: Text -> [Text] -> Maybe Text -> Text -> [Finding]
cliHelpFindings executable verb pinned current = case pinned of
  Nothing -> [Finding Changed (command <> " --help has no pinned text")]
  Just golden
    | golden == current -> []
    | not (Set.null removed) ->
        [Finding Breaking (command <> " no longer offers: " <> Text.intercalate ", " (Set.toAscList removed))]
    | otherwise -> [Finding Changed (command <> " --help text changed; every pinned option and command is still offered")]
    where
      removed = helpVocabulary golden `Set.difference` helpVocabulary current
  where
    command = Text.unwords (executable : verb)

-- | The names a help text offers: its long and short options, and the
-- subcommands listed under "Available commands".
helpVocabulary :: Text -> Set Text
helpVocabulary text = Set.fromList (options <> commands)
  where
    options =
      [ option
      | word <- Text.words (Text.map separator text),
        Just option <- [optionName word]
      ]
    separator character = if character `elem` (",|[]()=" :: String) then ' ' else character
    optionName word
      | Just name <- Text.stripPrefix "--" word, valid name = Just ("--" <> Text.takeWhile nameCharacter name)
      | Just name <- Text.stripPrefix "-" word, Text.length name == 1, Text.all isAlphaNum name = Just word
      | otherwise = Nothing
    valid name = not (Text.null name) && nameCharacter (Text.head name) && Text.head name /= '-'
    nameCharacter character = isAlphaNum character || character == '-'
    commands =
      [ command
      | line <- takeWhile (not . Text.null . Text.strip) (drop 1 (dropWhile (not . Text.isPrefixOf "Available commands") (Text.lines text))),
        command : _ <- [Text.words line],
        "  " `Text.isPrefixOf` line,
        not ("   " `Text.isPrefixOf` Text.drop 2 line)
      ]

-- | The golden file of a verb: @shikigami@, @shikigami runs show@ and so on.
goldenName :: Text -> [Text] -> FilePath
goldenName executable verb = Text.unpack (Text.intercalate "." (executable : verb)) <> ".txt"
