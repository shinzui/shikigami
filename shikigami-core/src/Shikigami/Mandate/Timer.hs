{-# LANGUAGE DataKinds #-}

module Shikigami.Mandate.Timer (fireAction) where

import Data.Aeson ((.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Effectful (Eff, IOE, (:>))
import Keiro.Timer (TimerRow (..), cancelTimer)
import Keiro.Workflow (awakeableStepPrefix, deterministicJournalId)
import Keiro.Workflow.Awakeable (awakeableIdText)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId)
import Shikigami.Coordination.Wake qualified as CheckpointWake
import Shikigami.Mandate.Store qualified as Mandates
import Shikigami.Mandate.Types
import Shikigami.Mandate.Wake qualified as Wake
import Shikigami.Prelude
import Shikigami.StateRevision (StateRevision)

fireAction :: (Store :> es, IOE :> es) => TimerRow -> Eff es (Maybe EventId)
fireAction row = case parseMaybe (Aeson.withObject "mandate timer" (\o -> (,,,) <$> o .: "kind" <*> o .: "mandateId" <*> o .: "revision" <*> o .: "listener")) row.payload of
  Just (kind, identifier, revision :: StateRevision "mandate", listener) | kind == Wake.timerKind -> do
    state <- runTransaction (Mandates.loadTx identifier)
    case state of
      Just actual | isNothing actual.stopReason && actual.wake == Just listener && revision == actual.revision && row.timerId == Wake.timerIdFor identifier listener -> do
        valid <- CheckpointWake.validateListener listener
        case valid of
          Right () -> do
            notify <- CheckpointWake.prepareListener listener
            runTransaction notify
            pure (Just (deterministicJournalId listener.ownerName listener.ownerId listener.generation (awakeableStepPrefix <> awakeableIdText listener.token)))
          _ -> void (cancelTimer row.timerId) >> pure Nothing
      _ -> void (cancelTimer row.timerId) >> pure Nothing
  _ -> pure Nothing
