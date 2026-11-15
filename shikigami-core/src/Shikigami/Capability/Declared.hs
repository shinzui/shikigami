-- | Tools an agent declaration names (EP-3 of MasterPlan 22).
--
-- A declared CLI tool is an executable, the argument patterns it may be
-- called with, its working directory and its operation class. The operator
-- grants the declaration once (ADR 0124); each declared tool then becomes the
-- capability overlay @cli.<name>@ with one logical tool, @run@, so the run's
-- authority decides every call and the action record shows it. Everything
-- here is pure; the host adapter that starts the process lives in
-- @shikigami-core:local-host@.
module Shikigami.Capability.Declared
  ( ToolName,
    mkToolName,
    toolNameText,
    ExecutableName,
    mkExecutableName,
    executableNameText,
    ArgumentWord,
    mkArgumentWord,
    argumentWordText,
    ExecutableRef (..),
    mkAtPath,
    executableRefText,
    Trailing (..),
    ArgumentPattern (..),
    WorkingDirectoryPolicy (..),
    SubdirectoryPath,
    mkSubdirectoryPath,
    subdirectoryPathText,
    CallTimeout,
    mkCallTimeout,
    callTimeoutSeconds,
    CallOutputLimit,
    mkCallOutputLimit,
    callOutputLimitBytes,
    CallLimits (..),
    defaultCallLimits,
    CliToolDecl (..),
    ToolDecl (..),
    cliTools,
    mcpRequests,
    cliCapabilityId,
    cliCapabilityName,
    toolLimits,
    matchesPattern,
    patternWithin,
    CliRefusal (..),
    decideCliArguments,
    renderCliRefusal,
    renderPattern,
    renderCliToolDecl,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.Char (isAsciiLower, isDigit, isSpace)
import Data.List (isPrefixOf)
import Data.List.NonEmpty (NonEmpty, nonEmpty)
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (FromDhall (..))
import Dhall qualified
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Shikigami.Capability.Mcp (McpToolRequest)
import Shikigami.Capability.Overlay (CapabilityId, CapabilityOperationClass, mkCapabilityId)
import System.FilePath (isAbsolute)

-- | @[a-z][a-z0-9-]{0,31}@: the tool's name, and the suffix of @cli.<name>@.
newtype ToolName = ToolName Text
  deriving stock (Eq, Ord, Show)

mkToolName :: Text -> Either Text ToolName
mkToolName value = case Text.uncons value of
  Just (first', rest)
    | isAsciiLower first',
      Text.length value <= 32,
      Text.all (\c -> isAsciiLower c || isDigit c || c == '-') rest ->
        Right (ToolName value)
  _ -> Left ("tool name " <> quoted value <> " must match [a-z][a-z0-9-]{0,31}")

toolNameText :: ToolName -> Text
toolNameText (ToolName value) = value

-- | A bare executable name looked up on @PATH@: no @/@ and no whitespace.
newtype ExecutableName = ExecutableName Text
  deriving stock (Eq, Ord, Show)

mkExecutableName :: Text -> Either Text ExecutableName
mkExecutableName value
  | Text.null value || Text.any (\c -> c == '/' || isSpace c) value = Left ("executable name " <> quoted value <> " must be one word without /")
  | otherwise = Right (ExecutableName value)

executableNameText :: ExecutableName -> Text
executableNameText (ExecutableName value) = value

-- | One argument word: not empty, no NUL, no newline.
newtype ArgumentWord = ArgumentWord Text
  deriving stock (Eq, Ord, Show)

mkArgumentWord :: Text -> Either Text ArgumentWord
mkArgumentWord value
  | Text.null value || Text.any (`elem` ['\0', '\n', '\r']) value = Left ("argument word " <> quoted value <> " must be non-empty and on one line")
  | otherwise = Right (ArgumentWord value)

argumentWordText :: ArgumentWord -> Text
argumentWordText (ArgumentWord value) = value

data ExecutableRef
  = OnPath !ExecutableName
  | AtPath !AbsoluteExecutable
  deriving stock (Eq, Ord, Show, Generic)

newtype AbsoluteExecutable = AbsoluteExecutable Text
  deriving stock (Eq, Ord, Show)

mkAbsoluteExecutable :: Text -> Either Text AbsoluteExecutable
mkAbsoluteExecutable value
  | isAbsolute (Text.unpack value) && not (Text.any isSpace value) = Right (AbsoluteExecutable value)
  | otherwise = Left ("executable path " <> quoted value <> " must be absolute")

-- | An executable named by its absolute path.
mkAtPath :: Text -> Either Text ExecutableRef
mkAtPath value = AtPath <$> mkAbsoluteExecutable value

executableRefText :: ExecutableRef -> Text
executableRefText = \case
  OnPath (ExecutableName value) -> value
  AtPath (AbsoluteExecutable value) -> value

-- | What may follow a pattern's fixed prefix.
data Trailing
  = NoTrailing
  | AnyTrailing
  | AtMostTrailing !Natural
  deriving stock (Eq, Ord, Show, Generic)

-- | An argument vector matches when it starts with @prefix@ and the rest
-- satisfies @trailing@.
data ArgumentPattern = ArgumentPattern
  { prefix :: ![ArgumentWord],
    trailing :: !Trailing
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | A relative directory below the workspace root, without @..@.
newtype SubdirectoryPath = SubdirectoryPath Text
  deriving stock (Eq, Ord, Show)

mkSubdirectoryPath :: Text -> Either Text SubdirectoryPath
mkSubdirectoryPath value
  | Text.null value || isAbsolute (Text.unpack value) || ".." `elem` Text.splitOn "/" value = Left ("working directory " <> quoted value <> " must be relative and inside the workspace")
  | otherwise = Right (SubdirectoryPath value)

subdirectoryPathText :: SubdirectoryPath -> Text
subdirectoryPathText (SubdirectoryPath value) = value

data WorkingDirectoryPolicy
  = WorkspaceRoot
  | WorkspaceSubdirectory !SubdirectoryPath
  deriving stock (Eq, Ord, Show, Generic)

-- | 1 to 600 seconds.
newtype CallTimeout = CallTimeout Natural
  deriving stock (Eq, Ord, Show)

mkCallTimeout :: Natural -> Either Text CallTimeout
mkCallTimeout seconds
  | seconds >= 1 && seconds <= 600 = Right (CallTimeout seconds)
  | otherwise = Left "a tool call timeout is 1 to 600 seconds"

callTimeoutSeconds :: CallTimeout -> Natural
callTimeoutSeconds (CallTimeout seconds) = seconds

-- | 1 byte to 4 MiB per stream.
newtype CallOutputLimit = CallOutputLimit Natural
  deriving stock (Eq, Ord, Show)

mkCallOutputLimit :: Natural -> Either Text CallOutputLimit
mkCallOutputLimit bytes
  | bytes >= 1 && bytes <= 4194304 = Right (CallOutputLimit bytes)
  | otherwise = Left "a tool output limit is 1 byte to 4 MiB per stream"

callOutputLimitBytes :: CallOutputLimit -> Natural
callOutputLimitBytes (CallOutputLimit bytes) = bytes

data CallLimits = CallLimits
  { timeoutSeconds :: !CallTimeout,
    outputBytes :: !CallOutputLimit
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | 60 seconds and 256 KiB per stream.
defaultCallLimits :: CallLimits
defaultCallLimits = CallLimits {timeoutSeconds = CallTimeout 60, outputBytes = CallOutputLimit 262144}

data CliToolDecl = CliToolDecl
  { name :: !ToolName,
    executable :: !ExecutableRef,
    allow :: !(NonEmpty ArgumentPattern),
    workingDirectory :: !WorkingDirectoryPolicy,
    operationClass :: !CapabilityOperationClass,
    limits :: !(Maybe CallLimits)
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | A tool a declaration names: a CLI tool, or approved tools of an MCP
-- server the operator's tools file binds.
data ToolDecl
  = CliTool !CliToolDecl
  | McpTools !McpToolRequest
  deriving stock (Eq, Ord, Show, Generic)

cliTools :: [ToolDecl] -> [CliToolDecl]
cliTools tools = [tool | CliTool tool <- tools]

mcpRequests :: [ToolDecl] -> [McpToolRequest]
mcpRequests tools = [request | McpTools request <- tools]

-- | @cli.<name>@, the capability overlay the tool is offered as.
cliCapabilityId :: ToolName -> CapabilityId
cliCapabilityId tool = either (error . show) id (mkCapabilityId (cliCapabilityName tool))

cliCapabilityName :: ToolName -> Text
cliCapabilityName tool = "cli." <> toolNameText tool

toolLimits :: CliToolDecl -> CallLimits
toolLimits CliToolDecl {limits} = maybe defaultCallLimits id limits

matchesPattern :: ArgumentPattern -> [Text] -> Bool
matchesPattern ArgumentPattern {prefix, trailing} arguments =
  let fixed = argumentWordText <$> prefix
   in fixed `isPrefixOf` arguments && trailingAdmits trailing (length arguments - length fixed)

trailingAdmits :: Trailing -> Int -> Bool
trailingAdmits trailing count = case trailing of
  NoTrailing -> count == 0
  AnyTrailing -> True
  AtMostTrailing most -> fromIntegral count <= most

-- | Whether every vector the first pattern admits, the second admits too.
patternWithin :: ArgumentPattern -> ArgumentPattern -> Bool
patternWithin inner outer =
  let innerFixed = argumentWordText <$> inner.prefix
      outerFixed = argumentWordText <$> outer.prefix
      extra = length innerFixed - length outerFixed
   in outerFixed `isPrefixOf` innerFixed && case (inner.trailing, outer.trailing) of
        (_, AnyTrailing) -> True
        (NoTrailing, NoTrailing) -> extra == 0
        (NoTrailing, AtMostTrailing most) -> fromIntegral extra <= most
        (AtMostTrailing words', AtMostTrailing most) -> fromIntegral extra + words' <= most
        _ -> False

data CliRefusal
  = ArgumentsOutsideDeclaredPatterns !ToolName ![Text]
  deriving stock (Eq, Show)

-- | Admit an argument vector only when one declared pattern matches it.
decideCliArguments :: CliToolDecl -> [Text] -> Either CliRefusal ()
decideCliArguments CliToolDecl {name, allow} arguments
  | any (`matchesPattern` arguments) allow = Right ()
  | otherwise = Left (ArgumentsOutsideDeclaredPatterns name arguments)

renderCliRefusal :: CliRefusal -> Text
renderCliRefusal = \case
  ArgumentsOutsideDeclaredPatterns tool _ ->
    "arguments outside declared patterns for " <> toolNameText tool

renderPattern :: ArgumentPattern -> Text
renderPattern ArgumentPattern {prefix, trailing} =
  Text.unwords (argumentWordText <$> prefix) <> case trailing of
    NoTrailing -> ""
    AnyTrailing -> " …"
    AtMostTrailing most -> " [up to " <> Text.pack (show most) <> " more]"

-- | One line for a grant confirmation or a tool description.
renderCliToolDecl :: CliToolDecl -> Text
renderCliToolDecl CliToolDecl {name, executable, allow, operationClass} =
  toolNameText name
    <> " ("
    <> executableRefText executable
    <> ", "
    <> Text.pack (show operationClass)
    <> "): "
    <> Text.intercalate "; " (renderPattern <$> foldr (:) [] allow)

quoted :: Text -> Text
quoted value = "\"" <> value <> "\""

-- Dhall: each checked word goes through its factory.

checked :: (b -> Either Text a) -> Dhall.Decoder b -> Dhall.Decoder a
checked parse Dhall.Decoder {extract = readBase, expected} =
  Dhall.Decoder
    { extract = \expression -> case Dhall.toMonadic (readBase expression) of
        Left problem -> Dhall.fromMonadic (Left problem)
        Right value -> either Dhall.extractError pure (parse value),
      expected
    }

instance FromDhall ToolName where autoWith _ = checked mkToolName Dhall.strictText

instance FromDhall ExecutableName where autoWith _ = checked mkExecutableName Dhall.strictText

instance FromDhall ArgumentWord where autoWith _ = checked mkArgumentWord Dhall.strictText

instance FromDhall AbsoluteExecutable where autoWith _ = checked mkAbsoluteExecutable Dhall.strictText

instance FromDhall SubdirectoryPath where autoWith _ = checked mkSubdirectoryPath Dhall.strictText

instance FromDhall CallTimeout where autoWith _ = checked mkCallTimeout Dhall.natural

instance FromDhall CallOutputLimit where autoWith _ = checked mkCallOutputLimit Dhall.natural

instance FromDhall ExecutableRef

instance FromDhall Trailing

instance FromDhall ArgumentPattern

instance FromDhall WorkingDirectoryPolicy

instance FromDhall CallLimits

-- | The Dhall form allows a list; an empty one is refused.
data CliToolDhall = CliToolDhall
  { name :: !ToolName,
    executable :: !ExecutableRef,
    allow :: ![ArgumentPattern],
    workingDirectory :: !WorkingDirectoryPolicy,
    operationClass :: !CapabilityOperationClass,
    limits :: !(Maybe CallLimits)
  }
  deriving stock (Generic)

instance FromDhall CliToolDhall

instance FromDhall CliToolDecl where
  autoWith options = checked fromDhallForm (autoWith options)
    where
      fromDhallForm CliToolDhall {name, executable, allow, workingDirectory, operationClass, limits} = case nonEmpty allow of
        Nothing -> Left ("tool " <> toolNameText name <> " declares no argument pattern")
        Just patterns -> Right CliToolDecl {name, executable, allow = patterns, workingDirectory, operationClass, limits}

-- | Tagged by alternative, as the Dhall union is.
instance FromDhall ToolDecl where
  autoWith options =
    Dhall.union
      ( (CliTool <$> Dhall.constructor "CliTool" (autoWith options))
          <> (McpTools <$> Dhall.constructor "McpTools" (autoWith options))
      )

-- JSON: the journal form, checked on the way back in.

viaText :: (Text -> Either Text a) -> Aeson.Value -> Parser a
viaText parse = Aeson.withText "word" (either (fail . Text.unpack) pure . parse)

viaNatural :: (Natural -> Either Text a) -> Aeson.Value -> Parser a
viaNatural parse value = parseJSON value >>= either (fail . Text.unpack) pure . parse

instance ToJSON ToolName where toJSON = toJSON . toolNameText

instance FromJSON ToolName where parseJSON = viaText mkToolName

instance ToJSON ExecutableName where toJSON = toJSON . executableNameText

instance FromJSON ExecutableName where parseJSON = viaText mkExecutableName

instance ToJSON ArgumentWord where toJSON = toJSON . argumentWordText

instance FromJSON ArgumentWord where parseJSON = viaText mkArgumentWord

instance ToJSON AbsoluteExecutable where toJSON (AbsoluteExecutable value) = toJSON value

instance FromJSON AbsoluteExecutable where parseJSON = viaText mkAbsoluteExecutable

instance ToJSON SubdirectoryPath where toJSON = toJSON . subdirectoryPathText

instance FromJSON SubdirectoryPath where parseJSON = viaText mkSubdirectoryPath

instance ToJSON CallTimeout where toJSON = toJSON . callTimeoutSeconds

instance FromJSON CallTimeout where parseJSON = viaNatural mkCallTimeout

instance ToJSON CallOutputLimit where toJSON = toJSON . callOutputLimitBytes

instance FromJSON CallOutputLimit where parseJSON = viaNatural mkCallOutputLimit

instance ToJSON ExecutableRef

instance FromJSON ExecutableRef

instance ToJSON Trailing

instance FromJSON Trailing

instance ToJSON ArgumentPattern

instance FromJSON ArgumentPattern

instance ToJSON WorkingDirectoryPolicy

instance FromJSON WorkingDirectoryPolicy

instance ToJSON CallLimits

instance FromJSON CallLimits

instance ToJSON CliToolDecl

instance FromJSON CliToolDecl

instance ToJSON ToolDecl

instance FromJSON ToolDecl
