-- | Dhall-declared playbooks (EP-4 of MasterPlan 22): the format, the checked
-- loader's rules, template rendering and the step tree.
--
-- A bundle names its main playbook and holds sibling playbooks; nesting and
-- fan-out name a sibling (@RunPlaybook@, @ForEach@) instead of embedding
-- steps, because Dhall has no recursive types. Text fields are templates:
-- @{{run.NAME}}@ reads a top-level string of the run's trigger payload and
-- @{{NAME}}@ reads a variable bound by an enclosing @ForEach@. Validation
-- refuses a reference to nothing, an unknown sibling and a cycle, naming the
-- step that is wrong.
module Shikigami.Playbook
  ( Bundle (..),
    Playbook (..),
    PlaybookStep (..),
    Items (..),
    stepId,
    PlaybookError (..),
    renderPlaybookError,
    validateBundle,
    lookupPlaybook,
    renderTemplate,
    templateReferences,
    renderStepTree,
    loadBundle,
  )
where

import Control.Exception (SomeException, try)
import Data.Aeson (FromJSON, ToJSON)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (FromDhall)
import Dhall qualified
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

data Bundle = Bundle
  { main :: !Text,
    playbooks :: ![Playbook]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data Playbook = Playbook
  { name :: !Text,
    steps :: ![PlaybookStep]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

-- | Items of a @ForEach@: literal texts, or a string array of the payload.
data Items
  = Literal ![Text]
  | FromPayload !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data PlaybookStep
  = -- | A coding agent works in @workspace@ (the run's repository when
    -- empty) and its change is committed on the run branch.
    CodingAgent {id :: !Text, prompt :: !Text, workspace :: !Text, deadlineMinutes :: !Natural}
  | -- | A declared tool of the playbook's declaration, as a durable step.
    Tool {id :: !Text, tool :: !Text, args :: ![Text], deadlineMinutes :: !Natural}
  | -- | Wait for the operator (the local inbox under the local operator).
    Approval {id :: !Text, prompt :: !Text}
  | -- | Run a sibling playbook once per item, binding the item to the
    -- variable named @item@.
    ForEach {id :: !Text, items :: !Items, item :: !Text, playbook :: !Text}
  | RunPlaybook {id :: !Text, playbook :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

stepId :: PlaybookStep -> Text
stepId = \case
  CodingAgent {id = value} -> value
  Tool {id = value} -> value
  Approval {id = value} -> value
  ForEach {id = value} -> value
  RunPlaybook {id = value} -> value

data PlaybookError
  = UnknownMainPlaybook !Text
  | DuplicatePlaybook !Text
  | DuplicateStep !Text !Text
  | UnknownSubPlaybook !Text !Text !Text
  | PlaybookCycle ![Text]
  | UndefinedReference !Text !Text !Text
  | EmptyStepId !Text
  deriving stock (Eq, Show)

renderPlaybookError :: PlaybookError -> Text
renderPlaybookError = \case
  UnknownMainPlaybook name -> "the main playbook " <> name <> " is not in the bundle"
  DuplicatePlaybook name -> "the bundle has two playbooks named " <> name
  DuplicateStep playbook step -> playbook <> "/" <> step <> ": two steps share this id"
  UnknownSubPlaybook playbook step target -> playbook <> "/" <> step <> ": no playbook named " <> target <> " in the bundle"
  PlaybookCycle path -> "playbooks run each other in a cycle: " <> Text.intercalate " -> " path
  UndefinedReference playbook step reference -> playbook <> "/" <> step <> ": {{" <> reference <> "}} names no run parameter or enclosing item"
  EmptyStepId playbook -> playbook <> ": a step has an empty id"

lookupPlaybook :: Bundle -> Text -> Maybe Playbook
lookupPlaybook Bundle {playbooks} wanted = case filter (\playbook -> playbook.name == wanted) playbooks of
  playbook : _ -> Just playbook
  [] -> Nothing

-- | Every error of the bundle, walking from the main playbook with the
-- variables each step can see.
validateBundle :: Bundle -> [PlaybookError]
validateBundle bundle@Bundle {main, playbooks} =
  [DuplicatePlaybook name | name <- nub names, length (filter (== name) names) > 1]
    <> case lookupPlaybook bundle main of
      Nothing -> [UnknownMainPlaybook main]
      Just root -> nub (walk [] [] root)
  where
    names = (.name) <$> playbooks
    walk path variables Playbook {name, steps} =
      let ids = stepId <$> steps
       in [EmptyStepId name | any Text.null ids]
            <> [DuplicateStep name step | step <- nub ids, length (filter (== step) ids) > 1]
            <> concatMap (checkStep (path <> [name]) variables name) steps
    checkStep path variables playbookName step =
      [UndefinedReference playbookName (stepId step) reference | reference <- references step, not (defined variables reference)]
        <> case step of
          ForEach {playbook = target, item = variable} -> into path (variables <> [variable]) playbookName (stepId step) target
          RunPlaybook {playbook = target} -> into path variables playbookName (stepId step) target
          _ -> []
    into path variables playbookName step target
      | target `elem` path = [PlaybookCycle (path <> [target])]
      | otherwise = case lookupPlaybook bundle target of
          Nothing -> [UnknownSubPlaybook playbookName step target]
          Just child -> walk path variables child
    defined variables reference = "run." `Text.isPrefixOf` reference || reference `elem` variables
    references = \case
      CodingAgent {prompt, workspace} -> templateReferences prompt <> templateReferences workspace
      Tool {args} -> concatMap templateReferences args
      Approval {prompt} -> templateReferences prompt
      ForEach {items = FromPayload _} -> []
      _ -> []

-- | The names inside @{{…}}@.
templateReferences :: Text -> [Text]
templateReferences template = case Text.breakOn "{{" template of
  (_, rest) | Text.null rest -> []
  (_, rest) ->
    let (reference, after) = Text.breakOn "}}" (Text.drop 2 rest)
     in Text.strip reference : templateReferences (Text.drop 2 after)

-- | Replace each @{{run.NAME}}@ and @{{NAME}}@; an unknown name is left as is
-- (validation refused it already).
renderTemplate :: Map Text Text -> Map Text Text -> Text -> Text
renderTemplate parameters variables template = case Text.breakOn "{{" template of
  (before, rest) | Text.null rest -> before
  (before, rest) ->
    let (reference, after) = Text.breakOn "}}" (Text.drop 2 rest)
        key = Text.strip reference
        value = case Text.stripPrefix "run." key of
          Just parameter -> Map.lookup parameter parameters
          Nothing -> Map.lookup key variables
     in before <> maybe ("{{" <> reference <> "}}") id value <> renderTemplate parameters variables (Text.drop 2 after)

-- | The step tree, one line per step, nested playbooks indented.
renderStepTree :: Bundle -> [Text]
renderStepTree bundle@Bundle {main} = maybe [] (go 0 []) (lookupPlaybook bundle main)
  where
    go depth path Playbook {name, steps} =
      (indent depth <> "playbook " <> name) : concatMap (stepLine (depth + 1) (path <> [name])) steps
    stepLine depth path step =
      let line = indent depth <> stepId step <> "  " <> describe step
          nested target = if target `elem` path then [] else maybe [] (go (depth + 1) path) (lookupPlaybook bundle target)
       in line : case step of
            ForEach {playbook = target} -> nested target
            RunPlaybook {playbook = target} -> nested target
            _ -> []
    describe = \case
      CodingAgent {deadlineMinutes, workspace} -> "coding agent, " <> Text.pack (show deadlineMinutes) <> " min" <> (if Text.null workspace then "" else " in " <> workspace)
      Tool {tool, args} -> "tool " <> tool <> " " <> Text.unwords args
      Approval {} -> "approval"
      ForEach {items, item, playbook} -> "for each " <> item <> " in " <> itemsText items <> " run " <> playbook
      RunPlaybook {playbook} -> "run " <> playbook
    itemsText = \case
      Literal values -> "[" <> Text.intercalate ", " values <> "]"
      FromPayload field -> "run." <> field
    indent depth = Text.replicate (2 * depth) " "

-- | Load and check a bundle file: a Dhall error, or every validation error.
loadBundle :: FilePath -> IO (Either [Text] Bundle)
loadBundle path = do
  loaded <- try @SomeException (Dhall.inputFile Dhall.auto path)
  pure case loaded of
    Left failure -> Left ["the playbook " <> Text.pack path <> " does not load: " <> Text.pack (show failure)]
    Right bundle -> case validateBundle bundle of
      [] -> Right bundle
      problems -> Left (renderPlaybookError <$> problems)
