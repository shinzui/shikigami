module Shikigami.Agent.Loader
  ( LoadError (..),
    loadAgent,
  )
where

import Control.Exception (SomeException, try)
import Data.Text qualified as Text
import Dhall (auto, inputFile)
import Shikigami.Agent.Decl (AgentDecl)
import Shikigami.Prelude

-- | A typed loader error. The Text carries Dhall's own (already very precise)
-- type-error / parse-error message.
newtype LoadError = LoadError Text
  deriving stock (Eq, Show)

-- | Parse and type-check a Dhall agent manifest into an AgentDecl. Returns Left
-- with a typed error if the file does not exist, fails to parse, or does not
-- type-check against the AgentDecl shape.
loadAgent :: FilePath -> IO (Either LoadError AgentDecl)
loadAgent path = do
  result <- try (inputFile auto path) :: IO (Either SomeException AgentDecl)
  pure $ case result of
    Left err -> Left (LoadError (Text.pack (show err)))
    Right decl -> Right decl
