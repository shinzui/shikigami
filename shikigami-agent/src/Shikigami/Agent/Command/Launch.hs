-- | Foreground Baikai launches. Process results never become durable Responses.
module Shikigami.Agent.Command.Launch
  ( LaunchCommand (..),
    LaunchConfig,
    launchParserInfo,
    launchConfigRun,
    launchRequest,
    launchInteractive,
    runLaunch,
  )
where

import Baikai.Agent (renderAgentRenderError)
import Baikai.Agent.Cli qualified as Agent
import Baikai.Interactive qualified as Interactive
import Baikai.Provider.Claude.Interactive qualified as Claude
import Baikai.Provider.OpenAI.Interactive qualified as Codex
import Baikai.ThinkingLevel (ThinkingLevel, parseThinkingLevel, renderThinkingLevel)
import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TextIO
import Options.Applicative qualified as Opt
import Settei
import Settei.Env
import Settei.Optparse (cliSources, resolutionDiagnostic, schemaDiagnostic)
import Shikigami.App.Config (jsonDecoder)
import Shikigami.App.Config.Load (ConfigOptions (..), captureEnvironment, configOptions, readConfigSources)
import System.Directory (canonicalizePath, doesDirectoryExist)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (isAbsolute, normalise)
import System.IO (hIsTerminalDevice, stderr, stdin, stdout)

data LaunchCommand
  = InteractiveLaunch !Text !(Maybe Text) !ConfigOptions
  | UnattendedLaunch !Agent.AgentCliOptions

data LaunchConfig = LaunchConfig
  { provider :: !Interactive.InteractiveProvider,
    model :: !(Maybe Text),
    thinking :: !(Maybe ThinkingLevel),
    workingDirectory :: !FilePath,
    extraDirectories :: ![FilePath],
    executable :: !(Maybe FilePath),
    arguments :: ![Text],
    sandbox :: !(Maybe Interactive.CodexSandboxMode),
    approval :: !(Maybe Interactive.CodexApprovalPolicy),
    allowedTools :: !(Maybe [Text])
  }

launchParserInfo :: Opt.ParserInfo LaunchCommand
launchParserInfo = Opt.info (parser Opt.<**> Opt.helper) (Opt.fullDesc <> Opt.progDesc "Foreground Baikai agent launches" <> Opt.failureCode 2)
  where
    parser =
      Opt.hsubparser
        ( Opt.command "interactive" (Opt.info (interactive Opt.<**> Opt.helper) (Opt.progDesc "Open an attended terminal session"))
            <> Opt.command "unattended" (Opt.info ((UnattendedLaunch <$> Agent.agentCliParser) Opt.<**> Opt.helper) (Opt.progDesc "Baikai named jobs: run, show, list"))
        )
    interactive =
      InteractiveLaunch
        <$> Opt.strOption (Opt.long "prompt" <> Opt.value "" <> Opt.metavar "TEXT")
        <*> Opt.optional (Opt.strOption (Opt.long "system-prompt" <> Opt.metavar "TEXT"))
        <*> configOptions

launchConfig :: Config LaunchConfig
launchConfig =
  LaunchConfig
    <$> required providerSetting
    <*> optional (textSetting "model" "Vendor model id; omitted means vendor default")
    <*> optional thinkingSetting
    <*> required (pathSetting "working_directory")
    <*> ( fromMaybe []
            <$> optional
              ( publicSetting
                  (stableLaunchKey "extra_directories")
                  "Additional authorized directories"
                  ( decoder \k raw -> do
                      values <- runDecoder jsonDecoder k raw
                      if all isAbsolute values then Right (map normalise values) else Left (decodeFailure k "an array of absolute directory paths")
                  )
              )
        )
    <*> (fmap Text.unpack <$> optional (textSetting "executable" "Vendor executable (host prerequisite)"))
    <*> (fromMaybe [] <$> optional (secretSetting (stableLaunchKey "arguments") "Operator provider arguments (redacted)" jsonDecoder))
    <*> optional sandboxSetting
    <*> optional approvalSetting
    <*> optional (publicSetting (stableLaunchKey "safety.claude_allowed_tools") "Claude tool preapproval list (not a deny list)" jsonDecoder)
  where
    providerSetting = publicSettingWithRenderer (stableLaunchKey "provider") "Attended vendor" (enumDecoder [("claude", Interactive.InteractiveClaude), ("codex", Interactive.InteractiveCodex)]) Interactive.renderInteractiveProvider
    thinkingSetting =
      publicSettingWithRenderer
        (stableLaunchKey "thinking")
        "Reasoning effort"
        ( decoder \k raw -> do
            value <- runDecoder textDecoder k raw
            maybe (Left (decodeFailure k "minimal, low, medium, high, xhigh or max")) Right (parseThinkingLevel value)
        )
        renderThinkingLevel
    sandboxSetting = publicSettingWithRenderer (stableLaunchKey "safety.codex_sandbox") "Explicit Codex sandbox" (enumDecoder [("read-only", Interactive.CodexReadOnly), ("workspace-write", Interactive.CodexWorkspaceWrite), ("danger-full-access", Interactive.CodexDangerFullAccess)]) Interactive.renderCodexSandboxMode
    approvalSetting = publicSettingWithRenderer (stableLaunchKey "safety.codex_approval") "Explicit Codex approval policy" (enumDecoder [("on-request", Interactive.CodexApprovalOnRequest), ("never", Interactive.CodexApprovalNever)]) Interactive.renderCodexApprovalPolicy

stableLaunchKey :: Text -> Key
stableLaunchKey suffix = either (error . show) id (parseKey ("launch." <> suffix))

textSetting :: Text -> Text -> Setting Text
textSetting suffix description =
  publicSettingWithRenderer
    (stableLaunchKey suffix)
    description
    ( decoder \k raw -> do
        value <- runDecoder textDecoder k raw
        if Text.null (Text.strip value) then Left (decodeFailure k "nonblank text") else Right value
    )
    id

absolutePathDecoder :: Decoder FilePath
absolutePathDecoder = decoder \k raw -> do
  value <- Text.unpack <$> runDecoder textDecoder k raw
  if isAbsolute value && not (null value) then Right (normalise value) else Left (decodeFailure k "an absolute directory path")

pathSetting :: Text -> Setting FilePath
pathSetting suffix = publicSettingWithRenderer (stableLaunchKey suffix) "Explicit absolute working directory" absolutePathDecoder Text.pack

launchBindings :: Bindings
launchBindings =
  either
    (error . Text.unpack . renderEnvErrorsText)
    id
    ( bindings
        [ binding (EnvName ("SHIKIGAMI_LAUNCH_" <> Text.toUpper (Text.replace "." "_" suffix))) (stableLaunchKey suffix)
        | suffix <- ["provider", "model", "thinking", "working_directory", "extra_directories", "executable", "arguments", "safety.codex_sandbox", "safety.codex_approval", "safety.claude_allowed_tools"]
        ]
    )

-- | Pure resolution/diagnostics. A Left is a complete exit/stream result;
-- Right is an admitted configuration. It probes no executable or login.
launchConfigRun :: ConfigOptions -> Either Text [Source] -> Source -> Either (ExitCode, Text, Text) LaunchConfig
launchConfigRun options files environment =
  case schemaDiagnostic options.diagnosticMode (describe launchConfig) of
    Just output -> Left (ExitSuccess, output, "")
    Nothing -> case files of
      Left problem -> failed 3 problem
      Right sources ->
        let result =
              resolve
                ResolveOptions {unknownKeyPolicy = RejectUnknownKeys}
                (sources <> [environment] <> options.namedSources <> cliSources "arguments" options.overrides)
                launchConfig
         in case result.answer of
              Left problems -> failed 4 (renderErrorsText problems)
              Right config -> case launchRequest config "" Nothing of
                Left refusal -> failed 4 refusal
                Right _ -> case resolutionDiagnostic options.diagnosticMode result of
                  Just output -> Left (ExitSuccess, output, renderWarningsText (result.warnings))
                  Nothing -> Right config
  where
    failed n problem = Left (ExitFailure n, "", problem <> "\n")

launchRequest :: LaunchConfig -> Text -> Maybe Text -> Either Text Interactive.InteractiveLaunchRequest
launchRequest config prompt system = do
  safety <- case config.provider of
    Interactive.InteractiveCodex
      | isJust config.allowedTools -> Left "launch.safety.claude_allowed_tools is incompatible with codex"
      | Just sandbox <- config.sandbox, Just approval <- config.approval -> Right (Interactive.CodexSandbox sandbox approval)
      | otherwise -> Left "launch.safety.codex_sandbox and launch.safety.codex_approval are required"
    Interactive.InteractiveClaude
      | isJust config.sandbox || isJust config.approval -> Left "launch.safety.codex_* is incompatible with claude"
      | Just tools <- config.allowedTools, not (null tools), all (not . Text.null . Text.strip) tools -> Right (Interactive.ClaudeAllowedTools tools)
      | otherwise -> Left "launch.safety.claude_allowed_tools requires an explicit nonempty preapproval list"
  let request =
        (Interactive.interactiveLaunchRequest prompt)
          { Interactive.systemPrompt = system,
            Interactive.modelId = config.model,
            Interactive.effort = config.thinking,
            Interactive.workingDir = Just config.workingDirectory,
            Interactive.extraDirs = config.extraDirectories,
            Interactive.extraArgs = config.arguments,
            Interactive.safety = safety
          }
  -- The public vendor renderer is the last pre-spawn authority.
  case config.provider of
    Interactive.InteractiveClaude -> either (Left . renderAgentRenderError) (const (Right request)) (Claude.claudeInteractiveCommand (claudeConfig config) request)
    Interactive.InteractiveCodex -> either (Left . renderAgentRenderError) (const (Right request)) (Codex.codexInteractiveCommand (codexConfig config) request)

claudeConfig :: LaunchConfig -> Claude.ClaudeInteractiveConfig
claudeConfig config = case config.executable of
  Nothing -> Claude.defaultClaudeInteractiveConfig
  Just executable -> Claude.defaultClaudeInteractiveConfig {Claude.executable = executable}

codexConfig :: LaunchConfig -> Codex.CodexInteractiveConfig
codexConfig config = case config.executable of
  Nothing -> Codex.defaultCodexInteractiveConfig
  Just executable -> Codex.defaultCodexInteractiveConfig {Codex.executable = executable}

-- | The terminal requirement is disabled only by deterministic fake tests.
launchInteractive :: Bool -> LaunchConfig -> Text -> Maybe Text -> IO (ExitCode, Text)
launchInteractive requireTerminal config prompt system = case launchRequest config prompt system of
  Left refusal -> pure (ExitFailure 4, refusal)
  Right request -> do
    terminal <- (&&) <$> hIsTerminalDevice stdin <*> hIsTerminalDevice stdout
    if requireTerminal && not terminal
      then pure (ExitFailure 2, "interactive launch requires a terminal")
      else
        if Text.null (Text.strip prompt)
          then pure (ExitFailure 2, "interactive launch requires --prompt")
          else do
            -- Resolve symlinks at the process boundary; configuration checks remain
            -- pure and need no live workspace, executable or authenticated session.
            outcome <- try @IOException do
              workingDirectory <- canonicalizePath config.workingDirectory
              extraDirectories <- traverse canonicalizePath config.extraDirectories
              existing <- traverse doesDirectoryExist (workingDirectory : extraDirectories)
              if not (and existing)
                then pure (ExitFailure 4, "launch directory does not exist")
                else do
                  let canonical = request {Interactive.workingDir = Just workingDirectory, Interactive.extraDirs = extraDirectories}
                  launched <- case config.provider of
                    Interactive.InteractiveClaude -> Claude.launchClaudeInteractive (claudeConfig config) canonical
                    Interactive.InteractiveCodex -> Codex.launchCodexInteractive (codexConfig config) canonical
                  pure (either (\err -> (ExitFailure 4, renderAgentRenderError err)) (\result -> (result.exitCode, "")) launched)
            -- Do not print IOException text: it can carry argument or prompt values.
            pure (either (const (ExitFailure 69, "vendor executable or directory unavailable")) id outcome)

runLaunch :: IO ()
runLaunch = do
  command <- Opt.execParser launchParserInfo
  case command of
    UnattendedLaunch options -> do
      snapshot <- captureEnvironment
      result <- Agent.runAgentCli snapshot options
      finish (if result.exitCode == 0 then ExitSuccess else ExitFailure result.exitCode) result.standardOutput result.standardError
    InteractiveLaunch prompt system options -> do
      files <- readConfigSources options.configPaths
      environment <- readEnvironmentSource launchBindings
      case launchConfigRun options files environment of
        Left (code, output, err) -> finish code output err
        Right config -> do
          TextIO.hPutStrLn stderr ("interactive provider=" <> Interactive.renderInteractiveProvider config.provider <> " model=" <> fromMaybe "vendor-default" config.model <> " cwd=" <> Text.pack config.workingDirectory)
          (code, detail) <- launchInteractive True config prompt system
          finish code "" (if Text.null detail then "" else detail <> "\n")
  where
    finish code output err = BS.hPut stdout (TE.encodeUtf8 output) >> BS.hPut stderr (TE.encodeUtf8 err) >> exitWith code
