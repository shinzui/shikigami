module Shikigami.Cli (main) where

import Options.Applicative
import Shikigami.Cli.Commands.Validate (runValidate)

newtype Command = Validate FilePath

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
    )

run :: Command -> IO ()
run (Validate file) = runValidate file
