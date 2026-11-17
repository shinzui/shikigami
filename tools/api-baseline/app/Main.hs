-- | @api-baseline@: check Shikigami's public surfaces against their pins.
--
-- Run it from the repository root, through @just api-baseline@.
module Main (main) where

import ApiBaseline.Exposure (measureExposure, neededModules, renderExposure)
import ApiBaseline.Inventory (loadInventory, renderInventoryError)
import ApiBaseline.Run (checkSurface, pinSurface)
import ApiBaseline.Types
import Control.Monad (forM, forM_, unless, when)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Options.Applicative
import System.Exit (ExitCode (..), exitWith)
import System.IO (stderr)

data Command
  = Check !FilePath !Bool ![Text]
  | Pin !FilePath !Text
  | List !FilePath !(Maybe Freeze)
  | Exposure !Bool

main :: IO ()
main =
  customExecParser (prefs showHelpOnEmpty) (info (commands <**> helper) (progDesc "Check Shikigami's public surfaces against a pinned inventory")) >>= \case
    Check inventory enforceAll only -> runCheck inventory enforceAll only
    Pin inventory surface -> runPin inventory surface
    List inventory freeze -> withInventory inventory \surfaces ->
      mapM_ (TextIO.putStrLn . (.name)) [surface | surface <- surfaces, maybe True (== surface.freeze) freeze]
    Exposure listNeeded -> do
      exposure <- measureExposure "."
      TextIO.putStrLn (renderExposure exposure)
      when listNeeded (mapM_ TextIO.putStrLn (Set.toAscList (neededModules exposure)))

commands :: Parser Command
commands =
  hsubparser
    ( command "check" (info checking (progDesc "Run every surface's check and print the report; exit 1 if an enforcing surface has a finding"))
        <> command "pin" (info pinning (progDesc "Re-pin one surface from the working tree after a deliberate, reviewed change"))
        <> command "list" (info listing (progDesc "Print the names of the registered surfaces"))
        <> command "exposure" (info (Exposure <$> switch (long "needed" <> help "Also list the needed modules, one per line, sorted")) (progDesc "Measure how much of shikigami-core is exposed and how much a consumer imports"))
    )
  where
    inventory = strArgument (metavar "INVENTORY" <> help "The inventory, api-baseline/surfaces.dhall")
    checking =
      Check
        <$> inventory
        <*> switch (long "enforce" <> help "Treat every surface as enforcing, whatever the inventory says")
        <*> many (strOption (long "only" <> metavar "SURFACE" <> help "Check only this surface; repeatable"))
    pinning = Pin <$> inventory <*> strArgument (metavar "SURFACE")
    listing = List <$> inventory <*> optional (option freeze (long "freeze" <> metavar "declaration|kernel" <> help "Only the surfaces this freeze pins"))
    freeze = eitherReader \case
      "declaration" -> Right Declaration
      "kernel" -> Right Kernel
      other -> Left ("unknown freeze " <> other <> "; expected declaration or kernel")

withInventory :: FilePath -> ([Surface] -> IO ()) -> IO ()
withInventory inventory use =
  loadInventory inventory >>= \case
    Left problem -> failTool (renderInventoryError problem)
    Right surfaces -> use surfaces

-- | Exit 2: the tool could not do its job. Distinct from exit 1, a finding
-- on an enforcing surface.
failTool :: Text -> IO a
failTool problem = TextIO.hPutStrLn stderr ("api-baseline: " <> problem) >> exitWith (ExitFailure 2)

runCheck :: FilePath -> Bool -> [Text] -> IO ()
runCheck inventory enforceAll only = withInventory inventory \registered -> do
  let chosen = [surface | surface <- registered, null only || surface.name `elem` only]
      enforcementOf surface = if enforceAll then Enforce else surface.enforcement
  forM_ only \name -> unless (name `elem` map (.name) registered) (failTool ("no surface named " <> name))
  outcomes <- forM chosen \surface -> (surface,) <$> checkSurface surface
  let enforcing = length (filter ((== Enforce) . enforcementOf) chosen)
      width = maximum (0 : map (Text.length . (.name)) chosen)
  TextIO.putStrLn
    ( "api-baseline: "
        <> count (length chosen)
        <> (if length chosen == 1 then " surface, " else " surfaces, ")
        <> count (length chosen - enforcing)
        <> " report-only, "
        <> count enforcing
        <> " enforcing"
    )
  forM_ outcomes \(surface, outcome) ->
    TextIO.putStrLn
      ( "  "
          <> Text.justifyLeft width ' ' surface.name
          <> "  "
          <> Text.justifyLeft 11 ' ' (stabilityText surface.stability)
          <> "  "
          <> either (const "COULD NOT RUN") status outcome
      )
  forM_ outcomes \(surface, outcome) -> case outcome of
    Right findings@(_ : _) -> TextIO.putStrLn "" >> TextIO.putStr (renderFinding surface findings)
    _ -> pure ()
  let unrunnable = [(surface, problem) | (surface, Left problem) <- outcomes]
      broken = [surface | (surface, Right findings) <- outcomes, Broken _ <- [verdict (enforcementOf surface) findings]]
  forM_ unrunnable \(surface, problem) -> TextIO.hPutStrLn stderr ("\napi-baseline: " <> surface.name <> " could not be checked: " <> problem)
  unless (null unrunnable) (exitWith (ExitFailure 2))
  when (not (null broken)) (exitWith (ExitFailure 1))
  where
    count = Text.pack . show
    status findings = case worstSeverity findings of
      Nothing -> "clean"
      Just Changed -> "CHANGED"
      Just Breaking -> "BREAKING"

runPin :: FilePath -> Text -> IO ()
runPin inventory name = withInventory inventory \surfaces ->
  case [surface | surface <- surfaces, surface.name == name] of
    [] -> failTool ("no surface named " <> name)
    surface : _ ->
      pinSurface inventory surface >>= \case
        Left problem -> failTool (name <> " was not pinned: " <> problem)
        Right [] -> TextIO.putStrLn (name <> ": already pinned to the working tree")
        Right files -> do
          TextIO.putStrLn (name <> ": pinned. Review the diff before committing:")
          mapM_ (TextIO.putStrLn . ("  " <>) . Text.pack) files
