-- | The local operator's approval inbox (EP-8 M2 of MasterPlan 22).
--
-- An ask is one file, @<inbox>/<review-id>.json@, written atomically with
-- mode 0600 in a directory of mode 0700. It holds the review id, the prompt,
-- the absolute deadline and the approval token. Nothing else holds the token:
-- not the log, not the action record, not @runs show@. The operator resolves
-- an ask with @shikigami-local approvals resolve@, which reads the token,
-- resolves the approval and deletes the file.
module Shikigami.Agent.Approval.LocalInbox
  ( PendingApproval (..),
    localInboxNotifier,
    listPendingApprovals,
    readPendingApproval,
    removePendingApproval,
    pendingToken,
    localInboxDirectory,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (FromJSON, ToJSON, Value)
import Data.Aeson qualified as Aeson
import Data.List (isSuffixOf, sortOn)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import GHC.Generics (Generic)
import Keiro.Workflow.Awakeable (AwakeableId (..), awakeableIdText)
import Shikigami.Agent.Approval (ApprovalRequest (..), reviewRequestIdText)
import Shikigami.Agent.Approval.Workflow (ApprovalNotificationError (..), ApprovalNotifier (..))
import Shikigami.Duration (durationTime)
import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory, removeFile, renameFile)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

data PendingApproval = PendingApproval
  { reviewId :: !Text,
    prompt :: !Text,
    context :: !Value,
    deadline :: !UTCTime,
    askedAt :: !UTCTime,
    token :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

localInboxNotifier :: FilePath -> ApprovalNotifier
localInboxNotifier inbox =
  ApprovalNotifier
    { recordPark = \_ _ _ _ -> pure (),
      postAsk = \reviewId awakeableId deadline request -> do
        now <- getCurrentTime
        createDirectoryIfMissing True inbox
        setFileMode inbox 0o700
        let pending =
              PendingApproval
                { reviewId = reviewRequestIdText reviewId,
                  prompt = Text.take 4096 request.prompt,
                  context = request.context,
                  deadline = addUTCTime (durationTime deadline) now,
                  askedAt = now,
                  token = awakeableIdText awakeableId
                }
            path = inbox </> (Text.unpack pending.reviewId <> ".json")
            staging = path <> ".tmp"
        written <- try @IOException do
          Aeson.encodeFile staging pending
          setFileMode staging 0o600
          renameFile staging path
        pure (either (Left . TransientNotification . Text.pack . show) Right written)
    }

-- | Open asks, oldest first.
listPendingApprovals :: FilePath -> IO [PendingApproval]
listPendingApprovals inbox = do
  listed <- try @IOException (listDirectory inbox)
  case listed of
    Left _ -> pure []
    Right names -> do
      decoded <- traverse (\name -> Aeson.decodeFileStrict' (inbox </> name)) [name | name <- names, ".json" `isSuffixOf` name]
      pure (sortOn (.askedAt) (catMaybes decoded))

readPendingApproval :: FilePath -> Text -> IO (Maybe PendingApproval)
readPendingApproval inbox reviewId = do
  let path = inbox </> (Text.unpack reviewId <> ".json")
  exists <- doesFileExist path
  if exists then Aeson.decodeFileStrict' path else pure Nothing

removePendingApproval :: FilePath -> Text -> IO ()
removePendingApproval inbox reviewId = do
  _ <- try @IOException (removeFile (inbox </> (Text.unpack reviewId <> ".json")))
  pure ()

-- | @<state_dir>/approvals@.
localInboxDirectory :: FilePath -> FilePath
localInboxDirectory stateDirectory = stateDirectory </> "approvals"

pendingToken :: PendingApproval -> Maybe AwakeableId
pendingToken pending = AwakeableId <$> UUID.fromText pending.token
