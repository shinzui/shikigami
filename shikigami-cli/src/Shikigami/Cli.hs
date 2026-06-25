module Shikigami.Cli (main) where

import Options.Applicative
import Shikigami.Cli.Commands.RunBehavior (runRunBehavior)
import Shikigami.Cli.Commands.Validate (runValidate)

data Command
  = Validate FilePath
  | RunBehavior FilePath (Maybe String)

main :: IO ()
main = run =<< execParser opts
  where
    opts = info (parser <**> helper) (fullDesc <> progDesc "shikigami declared-agent runtime")

parser :: Parser Command
parser =
  subparser
    ( command
        "validate"
        ( info
            (Validate <$> argument str (metavar "FILE"))
            (progDesc "Parse and validate an agent manifest (.dhall)")
        )
        <> command
          "run-behavior"
          ( info
              ( RunBehavior
                  <$> strOption (long "agent" <> metavar "FILE" <> help "Agent manifest (.dhall)")
                  <*> optional (strOption (long "payload" <> metavar "JSON" <> help "Trigger payload as JSON"))
              )
              (progDesc "Run an agent's behavior with deterministic stubs (no DB, no key)")
          )
    )

run :: Command -> IO ()
run (Validate file) = runValidate file
run (RunBehavior file payload) = runRunBehavior file payload
