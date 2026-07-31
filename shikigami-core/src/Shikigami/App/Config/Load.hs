-- | Turning sources into one resolved 'AppConfig', and saying what happened.
--
-- "Shikigami.App.Config" declares what configuration exists. This module decides
-- where candidate values come from, in what order they override one another,
-- what a process prints when something is wrong, and with what status it exits.
-- Every Shikigami executable goes through 'runAppConfig'; none of them assemble
-- sources themselves.
--
-- == Precedence
--
-- Sources are resolved low to high, so a later source wins and the resolution
-- report keeps the shadowed candidates:
--
--  1. declared defaults (from "Shikigami.App.Config", not a source at all —
--     Settei supplies them when no source does, and reports the rule that did);
--  2. each @--config PATH@ YAML file, in the order the options appear;
--  3. explicitly bound environment variables;
--  4. named command-line options such as @--broker@ or @--agents@;
--  5. each @--set KEY=VALUE@ override, in the order the options appear.
--
-- Files sit below the environment so a deployment can override a checked-in file
-- without editing it, and both sit below the command line so that an operator
-- typing an explicit flag during an incident always wins. Repeating an option is
-- not an error: the last occurrence wins and the earlier ones stay visible in
-- @--explain-config@.
--
-- Unknown keys are rejected rather than warned about. A misspelled key in a
-- configuration file is indistinguishable at runtime from a key that was never
-- set, and silently starting with the wrong value is the failure mode this whole
-- plan exists to remove.
--
-- == Diagnostics and exit codes
--
-- Five flags are available on every configurable executable.
-- @--describe-config@ and @--describe-config-json@ print the static schema
-- without loading a single source. @--explain-config@ and
-- @--explain-config-json@ print where every resolved value came from, including
-- shadowed candidates. @--check-config@ validates and exits. All five stop
-- before any database connection, queue creation, listener, or worker
-- registration, because 'runAppConfig' returns only in the no-diagnostic case
-- and the callers do their work afterwards.
--
-- Exit codes are reserved: @2@ for command-line usage errors (owned by
-- @optparse-applicative@ via 'usageExitCode'), @3@ for source input and parsing
-- failures, @4@ for typed resolution failures — including a value that decoded
-- badly and a key a role requires but nothing supplied. A malformed winning
-- value is fatal; resolution never falls back to a lower candidate.
module Shikigami.App.Config.Load
  ( -- * Parsing the command line
    ConfigOptions (..),
    DiagnosticMode (..),
    configOptions,
    configOptionsWith,
    withConfigOptions,

    -- * Loading
    runAppConfig,
    requireDatabaseUrl,

    -- * The capturable core
    ConfigRun (..),
    appConfigRun,
    readConfigSources,
    resolveAppConfig,

    -- * Exit codes
    usageExitCode,
    sourceExitCode,
    resolutionExitCode,
  )
where

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import GHC.Generics (Generic)
import Options.Applicative (Parser, ParserInfo)
import Options.Applicative qualified as Options
import Settei
import Settei.Env
-- Imported explicitly: 'SetteiOptions' has fields with the same names as
-- 'ConfigOptions', and this module wants its own.
import Settei.Optparse
  ( CliOverride,
    DiagnosticMode (..),
    cliSources,
    configPathOptions,
    diagnosticModeOptions,
    overrideOptions,
    resolutionDiagnostic,
    schemaDiagnostic,
  )
import Settei.Yaml
import Shikigami.App.Config
import System.Exit (ExitCode (..), exitWith)
import System.IO qualified as IO

-- ── Exit codes ──────────────────────────────────────────────────────────────

-- | Reserved for command-line usage errors, produced by @optparse-applicative@.
usageExitCode :: Int
usageExitCode = 2

-- | Reserved for source input failures: a missing file, unreadable bytes, or
-- YAML that does not parse.
sourceExitCode :: Int
sourceExitCode = 3

-- | Reserved for typed resolution failures: a value that did not decode, an
-- unknown key, or a key this role requires and nothing supplied.
resolutionExitCode :: Int
resolutionExitCode = 4

-- ── Parsing the command line ────────────────────────────────────────────────

-- | Everything the command line contributes to configuration.
--
-- 'namedSources' holds the operator-friendly flags a binary chooses to keep, for
-- example @--broker HOST:PORT@ on the stream consumer. They are ordinary Settei
-- sources aimed at declared keys, which is why @--broker@ and
-- @--set kafka.broker=…@ mean exactly the same thing and both show up in
-- @--explain-config@ with their spelling.
data ConfigOptions = ConfigOptions
  { configPaths :: ![FilePath],
    namedSources :: ![Source],
    overrides :: ![CliOverride],
    diagnosticMode :: !DiagnosticMode
  }
  deriving stock (Generic)

-- | The configuration and diagnostic options every executable accepts.
configOptions :: Parser ConfigOptions
configOptions = configOptionsWith (pure [])

-- | 'configOptions' plus a binary's own named flags.
--
-- The argument parses zero or more sources; a binary builds it from
-- 'Settei.Optparse.namedOption' for string-valued flags and from
-- 'Settei.Optparse.cliOverride' for switches. Absent flags contribute nothing,
-- so a flag that is not passed leaves the environment or the declared default in
-- place.
configOptionsWith :: Parser [Source] -> Parser ConfigOptions
configOptionsWith named =
  assemble
    <$> Options.parserOptionGroup "Configuration" ((,,) <$> configPathOptions <*> named <*> overrideOptions)
    <*> Options.parserOptionGroup "Diagnostics" diagnosticModeOptions
  where
    assemble (paths, sources, sets) mode =
      ConfigOptions
        { configPaths = paths,
          namedSources = sources,
          overrides = sets,
          diagnosticMode = mode
        }

-- | Build a 'ParserInfo' whose result is the resolved configuration paired with
-- the binary's own arguments.
--
-- Exists so every executable gets identical option groups, identical help, and
-- the reserved usage exit code without repeating the wiring. The action runs
-- only when no diagnostic was requested.
withConfigOptions ::
  -- | Program description for @--help@.
  String ->
  -- | The binary's own arguments, if any.
  Parser a ->
  -- | The binary's named configuration flags.
  Parser [Source] ->
  ParserInfo (a, ConfigOptions)
withConfigOptions description own named =
  Options.info
    (((,) <$> own <*> configOptionsWith named) Options.<**> Options.helper)
    ( Options.fullDesc
        <> Options.progDesc description
        <> Options.failureCode usageExitCode
    )

-- ── Loading ─────────────────────────────────────────────────────────────────

-- | Everything one configuration attempt produced.
--
-- Separated from the process actions so tests can assert on exactly what would
-- be printed and with what status, including that a planted secret appears in
-- none of it.
data ConfigRun = ConfigRun
  { exitCode :: !Int,
    standardOutput :: !Text,
    standardError :: !Text,
    -- | The resolved configuration, present only when the process should carry
    -- on: resolution succeeded, the role's requirements were met, and no
    -- diagnostic was requested.
    resolved :: !(Maybe AppConfig)
  }
  deriving stock (Generic)

-- | Resolve configuration for a role, print what it has to say, and either
-- return the configuration or exit.
--
-- This is the only configuration entry point an executable should call. It
-- returns only when the process is meant to keep running; a diagnostic mode, a
-- source failure, a resolution failure, or an unmet role requirement all exit
-- here, before the caller has opened anything.
runAppConfig :: Role -> ConfigOptions -> IO AppConfig
runAppConfig role options = do
  fileSources <- readConfigSources (configPaths options)
  environment <- readEnvironmentSource environmentBindings
  let run = appConfigRun role options fileSources environment
  TextIO.putStr (standardOutput run)
  TextIO.hPutStr IO.stderr (standardError run)
  case resolved run of
    Just config | exitCode run == 0 -> pure config
    _ -> exitWith (if exitCode run == 0 then ExitSuccess else ExitFailure (exitCode run))

-- | Read every @--config PATH@ file, in order.
--
-- Returns the failure text rather than throwing so the caller can pair it with
-- the reserved source exit code. YAML adapter errors already name the file,
-- line, and column, and deliberately never echo the offending value.
readConfigSources :: [FilePath] -> IO (Either Text [Source])
readConfigSources paths = fmap sequenceEither (traverse readOne paths)
  where
    readOne path = do
      loaded <- readYamlSource (withYamlSourcePath path (yamlSourceOptions (Text.pack path))) path
      pure (either (Left . renderYamlErrorsText) Right loaded)

sequenceEither :: [Either Text Source] -> Either Text [Source]
sequenceEither = foldr step (Right [])
  where
    step (Left problem) _ = Left problem
    step (Right value) acc = fmap (value :) acc

-- | One complete configuration attempt, as data.
--
-- Pure on purpose: reading the files and snapshotting the environment happen in
-- 'runAppConfig', and everything that decides what to print, what to return, and
-- how to exit happens here where a test can look at it.
appConfigRun ::
  Role ->
  ConfigOptions ->
  -- | File sources, or the failure that stopped them being read.
  Either Text [Source] ->
  -- | The environment source.
  Source ->
  ConfigRun
appConfigRun role options fileSources environment =
  case schemaDiagnostic (diagnosticMode options) appConfigSchema of
    Just output -> succeeded output ""
    Nothing -> case fileSources of
      Left problem -> failed sourceExitCode problem
      Right files ->
        let result = resolveAppConfig options files environment
            warnings = renderWarningsText (warningsOf result)
         in case answerOf result of
              Left problems -> failed resolutionExitCode (renderErrorsText problems <> explainOnFailure options result)
              Right config -> case missingRequirements role config of
                missing@(_ : _) -> failed resolutionExitCode (renderMissing role missing)
                [] -> case resolutionDiagnostic (diagnosticMode options) result of
                  Just output -> succeeded output warnings
                  Nothing -> (succeeded "" warnings) {resolved = Just config}
  where
    succeeded output warnings =
      ConfigRun {exitCode = 0, standardOutput = output, standardError = warnings, resolved = Nothing}
    failed code problem =
      ConfigRun {exitCode = code, standardOutput = "", standardError = problem, resolved = Nothing}

-- | Assemble the sources in precedence order and resolve.
--
-- Exposed so a test can drive precedence with hand-built sources and no files or
-- process environment at all.
resolveAppConfig :: ConfigOptions -> [Source] -> Source -> ResolveResult AppConfig
resolveAppConfig options files environment =
  resolve
    ResolveOptions {unknownKeyPolicy = RejectUnknownKeys}
    ( files
        <> [environment]
        <> namedSources options
        <> cliSources "arguments" (overrides options)
    )
    appConfig

-- | Provenance is appended to a failure only when it was explicitly asked for.
--
-- A resolution report names every source that offered a value; printing it on
-- every failure would put file paths and variable names into logs that only
-- needed the error.
explainOnFailure :: ConfigOptions -> ResolveResult AppConfig -> Text
explainOnFailure options result = case diagnosticMode options of
  ExplainText -> renderResolutionText (reportOf result)
  ExplainJson -> renderResolutionJson (reportOf result) <> "\n"
  _ -> ""

renderMissing :: Role -> [Key] -> Text
renderMissing role missing =
  Text.unlines
    [ roleBinary role <> ": " <> renderKey key <> " is required by this process but no source supplied it"
    | key <- missing
    ]

-- | Demand the database connection string at the point a command opens a store.
--
-- Used by the administrative subcommands, whose sibling subcommands run entirely
-- offline: requiring a connection string for the whole @shikigami@ command line
-- would make @shikigami validate@ fail on a laptop with no database. The message
-- names the same key an operator would set, and the exit code is the same one a
-- missing required key produces anywhere else.
requireDatabaseUrl :: Text -> AppConfig -> IO SecretText
requireDatabaseUrl commandName config = case databaseUrl config of
  Just secret | not (Text.null (revealSecretText secret)) -> pure secret
  _ -> do
    TextIO.hPutStrLn
      IO.stderr
      ( commandName
          <> ": "
          <> renderKey databaseConnectionStringKey
          <> " is required by this command but no source supplied it"
      )
    exitWith (ExitFailure resolutionExitCode)

-- ── Reaching into Settei's result record ────────────────────────────────────
--
-- @ResolveResult@'s fields collide with names this module already uses, so they
-- are read through these three accessors instead of by importing the field
-- selectors.

answerOf :: ResolveResult a -> Either (NonEmpty ConfigError) a
answerOf ResolveResult {answer} = answer

reportOf :: ResolveResult a -> ResolutionReport
reportOf ResolveResult {report} = report

warningsOf :: ResolveResult a -> [ConfigWarning]
warningsOf ResolveResult {warnings} = warnings
