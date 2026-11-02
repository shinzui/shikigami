{-# LANGUAGE DataKinds #-}

module Shikigami.Objective.HttpEnvelope (envelope, schemaValue) where

import Data.Aeson ((.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.OpenApi (Schema)
import Shikigami.FormatVersion (FormatVersion)
import Shikigami.Prelude

envelope :: [Key] -> Aeson.Object -> Parser ()
envelope allowed fields = do
  unless (all (`elem` allowed) (KeyMap.keys fields)) (fail "unknown envelope field")
  void (fields .: "format" :: Parser (FormatVersion "objective-http-envelope"))

schemaValue :: Aeson.Value -> Schema
schemaValue value = case Aeson.fromJSON value of Aeson.Success schema -> schema; Aeson.Error message -> error message
