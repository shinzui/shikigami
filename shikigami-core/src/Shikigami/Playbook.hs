-- | Dhall-declared playbooks (EP-4 of MasterPlan 22): the format, the checked
-- loader's rules, template rendering and the step tree.
--
-- A bundle names its main playbook and holds sibling playbooks; nesting and
-- fan-out name a sibling (@RunPlaybook@, @ForEach@) instead of embedding
-- steps, because Dhall has no recursive types. Text fields are templates:
-- @{{run.NAME}}@ reads a top-level string of the run's trigger payload and
-- @{{NAME}}@ reads a variable bound by an enclosing @ForEach@,
-- @{{steps.ID.summary}}@ and @{{steps.ID.output}}@ an earlier step of the same
-- playbook (observed, like step-sourced items), and @{{learnings}}@ the
-- learnings recorded so far. Validation
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
    PinnedPlaybook (..),
    pinPlaybook,
  )
where

import Control.Exception (SomeException, try)
import Data.Aeson (FromJSON, ToJSON)
import Data.List (nub)
import Data.List qualified as List
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (FromDhall)
import Dhall qualified
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import System.Directory (doesPathExist, makeAbsolute)
import System.FilePath (makeRelative, takeDirectory, (</>))

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

-- | Items of a @ForEach@: literal texts, a string array of the payload, or
-- an array in an earlier step's JSON output (a coding agent's last JSON
-- line, or a tool's standard output) at a JSON pointer. An array of objects
-- takes each item's key from its @key@ field and binds each string field
-- @f@ as @{{ITEM.f}}@. Items from step output are observed: they may be
-- quoted in prompts and passed as tool arguments, never name a workspace.
data Items
  = Literal ![Text]
  | FromPayload !Text
  | FromStep {step :: !Text, at :: !Text, key :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data PlaybookStep
  = -- | A coding agent works in @workspace@ (the run's repository when
    -- empty) and its change is committed on the run branch.
    -- @skills@ are skill directories, relative to the bundle, attached to
    -- the agent.
    CodingAgent {id :: !Text, prompt :: !Text, workspace :: !Text, deadlineMinutes :: !Natural, skills :: ![Text]}
  | -- | A declared tool of the playbook's declaration, as a durable step.
    Tool {id :: !Text, tool :: !Text, args :: ![Text], deadlineMinutes :: !Natural}
  | -- | A declared tool that reports through its exit code: any exit is a
    -- result (quoted through @{{steps.ID.output}}@ with the exit code), and
    -- only a refusal, a failure to start, a timeout or an uncertain outcome
    -- ends the run.
    Probe {id :: !Text, tool :: !Text, args :: ![Text], deadlineMinutes :: !Natural}
  | -- | A 'Tool' step that runs in @workspace@ (the run's repository when
    -- empty), in that repository's worktree of this run, under the grant the
    -- declaration holds for it.
    ToolIn {id :: !Text, tool :: !Text, args :: ![Text], deadlineMinutes :: !Natural, workspace :: !Text}
  | -- | A 'Probe' step that runs in @workspace@, as 'ToolIn' does.
    ProbeIn {id :: !Text, tool :: !Text, args :: ![Text], deadlineMinutes :: !Natural, workspace :: !Text}
  | -- | Wait for the operator (the local inbox under the local operator).
    Approval {id :: !Text, prompt :: !Text}
  | -- | Run a sibling playbook once per item, binding the item to the
    -- variable named @item@.
    ForEach {id :: !Text, items :: !Items, item :: !Text, playbook :: !Text}
  | RunPlaybook {id :: !Text, playbook :: !Text}
  | -- | A read-only coding agent reflects on the work in @workspace@ and
    -- answers with learnings (quoted to later steps through
    -- @{{learnings}}@ and kept for later runs) and an optional suggestion
    -- for the bundle, which the run proposes on a branch when it ends.
    Reflect {id :: !Text, prompt :: !Text, workspace :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

stepId :: PlaybookStep -> Text
stepId = \case
  CodingAgent {id = value} -> value
  Tool {id = value} -> value
  Probe {id = value} -> value
  ToolIn {id = value} -> value
  ProbeIn {id = value} -> value
  Approval {id = value} -> value
  ForEach {id = value} -> value
  RunPlaybook {id = value} -> value
  Reflect {id = value} -> value

data PlaybookError
  = UnknownMainPlaybook !Text
  | DuplicatePlaybook !Text
  | DuplicateStep !Text !Text
  | UnknownSubPlaybook !Text !Text !Text
  | PlaybookCycle ![Text]
  | UndefinedReference !Text !Text !Text
  | EmptyStepId !Text
  | UnknownSourceStep !Text !Text !Text
  | ObservedWorkspace !Text !Text !Text
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
  UnknownSourceStep playbook step source -> playbook <> "/" <> step <> ": items come from " <> source <> ", which is not an earlier step of this playbook"
  ObservedWorkspace playbook step reference -> playbook <> "/" <> step <> ": the workspace names {{" <> reference <> "}}, which comes from step output; a repository must come from the bundle or the payload"

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
    -- Variables are (name, observed).
    walk path variables Playbook {name, steps} =
      let ids = stepId <$> steps
       in [EmptyStepId name | any Text.null ids]
            <> [DuplicateStep name step | step <- nub ids, length (filter (== step) ids) > 1]
            <> concat (zipWith (\earlier step -> checkStep (path <> [name]) variables name earlier step) (List.inits ids) steps)
    checkStep path variables playbookName earlier step =
      [UndefinedReference playbookName (stepId step) reference | reference <- references step, not (defined variables reference || earlierStepReference earlier reference)]
        <> [ObservedWorkspace playbookName (stepId step) reference | reference <- workspaceReferences step, observed variables reference || "steps." `Text.isPrefixOf` reference]
        <> case step of
          ForEach {items = FromStep {step = source}}
            | source `notElem` earlier -> [UnknownSourceStep playbookName (stepId step) source]
          _ -> []
        <> case step of
          ForEach {playbook = target, item = variable, items} -> into path (variables <> [(variable, isObserved items)]) playbookName (stepId step) target
          RunPlaybook {playbook = target} -> into path variables playbookName (stepId step) target
          _ -> []
    isObserved = \case
      FromStep {} -> True
      _ -> False
    workspaceReferences = \case
      CodingAgent {workspace} -> templateReferences workspace
      Reflect {workspace} -> templateReferences workspace
      ToolIn {workspace} -> templateReferences workspace
      ProbeIn {workspace} -> templateReferences workspace
      _ -> []
    variableOf reference = fst (Text.breakOn "." reference)
    observed variables reference = maybe False id (lookup (variableOf reference) variables)
    -- steps.ID.summary or steps.ID.output of an earlier step of this playbook.
    earlierStepReference earlier reference = case Text.splitOn "." reference of
      ["steps", source, field] -> source `elem` earlier && field `elem` ["summary", "output"]
      _ -> False
    into path variables playbookName step target
      | target `elem` path = [PlaybookCycle (path <> [target])]
      | otherwise = case lookupPlaybook bundle target of
          Nothing -> [UnknownSubPlaybook playbookName step target]
          Just child -> walk path variables child
    defined variables reference =
      "run." `Text.isPrefixOf` reference
        || reference == "learnings"
        || reference `elem` (fst <$> variables)
        || maybe False id (lookup (variableOf reference) variables)
    references = \case
      CodingAgent {prompt, workspace} -> templateReferences prompt <> templateReferences workspace
      Tool {args} -> concatMap templateReferences args
      Probe {args} -> concatMap templateReferences args
      ToolIn {args, workspace} -> concatMap templateReferences args <> templateReferences workspace
      ProbeIn {args, workspace} -> concatMap templateReferences args <> templateReferences workspace
      Approval {prompt} -> templateReferences prompt
      Reflect {prompt, workspace} -> templateReferences prompt <> templateReferences workspace
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
      Probe {tool, args} -> "probe " <> tool <> " " <> Text.unwords args
      ToolIn {tool, args, workspace} -> "tool " <> tool <> " " <> Text.unwords args <> inWorkspace workspace
      ProbeIn {tool, args, workspace} -> "probe " <> tool <> " " <> Text.unwords args <> inWorkspace workspace
      Approval {} -> "approval"
      ForEach {items, item, playbook} -> "for each " <> item <> " in " <> itemsText items <> " run " <> playbook
      RunPlaybook {playbook} -> "run " <> playbook
      Reflect {workspace} -> "reflect" <> (if Text.null workspace then "" else " in " <> workspace)
    itemsText = \case
      Literal values -> "[" <> Text.intercalate ", " values <> "]"
      FromPayload field -> "run." <> field
      FromStep {step, at} -> step <> " output" <> (if Text.null at then "" else " at " <> at)
    indent depth = Text.replicate (2 * depth) " "
    inWorkspace workspace = if Text.null workspace then "" else " in " <> workspace

-- | Load and check a bundle file: a Dhall error, or every validation error.
loadBundle :: FilePath -> IO (Either [Text] Bundle)
loadBundle path = do
  loaded <- try @SomeException (Dhall.inputFile Dhall.auto path)
  pure case loaded of
    Left failure -> Left ["the playbook " <> Text.pack path <> " does not load: " <> Text.pack (show failure)]
    Right bundle -> case validateBundle bundle of
      [] -> Right bundle
      problems -> Left (renderPlaybookError <$> problems)

-- | A checked bundle as a run pins it: the bundle, its file, and the Git
-- repository that holds the file (where a suggestion is proposed).
data PinnedPlaybook = PinnedPlaybook
  { bundle :: !Bundle,
    file :: !FilePath,
    repository :: !(Maybe FilePath),
    -- | The file relative to 'repository'.
    relative :: !FilePath
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

pinPlaybook :: FilePath -> IO (Either [Text] PinnedPlaybook)
pinPlaybook path = do
  file <- makeAbsolute path
  loaded <- loadBundle file
  case loaded of
    Left problems -> pure (Left problems)
    Right bundle -> do
      repository <- enclosingRepository (takeDirectory file)
      pure (Right PinnedPlaybook {bundle, file, repository, relative = maybe file (`makeRelative` file) repository})
  where
    enclosingRepository directory = do
      found <- doesPathExist (directory </> ".git")
      if found
        then pure (Just directory)
        else
          let parent = takeDirectory directory
           in if parent == directory then pure Nothing else enclosingRepository parent
