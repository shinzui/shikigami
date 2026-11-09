{-# LANGUAGE DataKinds #-}

module Shikigami.Server.Command.Mandates where

import Data.Aeson (object, (.=))
import Shikigami.App.Config (AppConfig)
import Shikigami.Execution.Identity (OperationId)
import Shikigami.Mandate.Store qualified as Mandates
import Shikigami.Mandate.Types
import Shikigami.Prelude hiding ((.=))
import Shikigami.Server.Command.Objectives (checked, readDocument, withObjectives)
import Shikigami.StateRevision (StateRevision)

runMandatesCreate :: OperationId -> FilePath -> Bool -> AppConfig -> IO ()
runMandatesCreate operation path _json config = do
  request <- readDocument path
  withObjectives config \host -> Mandates.admitMandate host operation request

runMandatesInspect :: Text -> Bool -> AppConfig -> IO ()
runMandatesInspect raw _json config = do
  identifier <- checked (parseMandateId raw)
  withObjectives config \host -> fmap (fmap (\(state, resources) -> object ["mandate" .= state, "resources" .= resources])) (Mandates.inspectWithResources host identifier)

runMandatesUpdate :: Text -> OperationId -> StateRevision "mandate" -> FilePath -> Bool -> AppConfig -> IO ()
runMandatesUpdate raw operation expected path _json config = do
  identifier <- checked (parseMandateId raw)
  request <- readDocument path
  withObjectives config \host -> Mandates.updateMandate host identifier expected operation request

runMandatesCancel :: Text -> OperationId -> StateRevision "mandate" -> Bool -> AppConfig -> IO ()
runMandatesCancel raw operation expected _json config = do
  identifier <- checked (parseMandateId raw)
  withObjectives config \host -> Mandates.stopMandate host identifier expected operation
