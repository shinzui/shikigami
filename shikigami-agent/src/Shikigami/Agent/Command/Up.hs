-- | @shikigami-local up@: run the operator's scheduled routine agents on this
-- machine (EP-9 M3 of MasterPlan 22).
--
-- It loads the agents directory, arms every scheduled agent whose current
-- declaration has a stored grant (in the repository of that grant), and says
-- why each other agent is not armed. Each due minute runs the agent through
-- the same light composition as @shikigami-local run@, unattended, so a run
-- never asks and a changed declaration is not run until it is confirmed again.
module Shikigami.Agent.Command.Up
  ( UpOptions (..),
    runUp,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_, unless, when)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (find, isSuffixOf, sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time (UTCTime (..), addUTCTime, getCurrentTime)
import Shikigami.Agent.Command.AgentRun (runAgentRun)
import Shikigami.Agent.Command.Routine (defaultAgentsDirectory)
import Shikigami.Agent.Decl (AgentDecl (..), Trigger (..))
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (agentNameText)
import Shikigami.App.Config (AppConfig (..))
import Shikigami.Repository (repositoryIdText)
import Shikigami.Trigger.Schedule (CronSchedule, cronExpressionText, isDue, parseCron)
import Shikigami.Trust.LocalOperator.Approvals
import Shikigami.Trust.LocalOperator.Grant
import Shikigami.Trust.Tier (TrustTier (LocalOperator))
import Shikigami.Workspace.Local.Checkout (processCheckoutResolver)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))

newtype UpOptions = UpOptions
  { -- | Stop after this many minutes (default: run until interrupted).
    forMinutes :: Maybe Int
  }

data Armed = Armed {path :: !FilePath, name :: !Text, cron :: !CronSchedule, checkout :: !FilePath}

runUp :: UpOptions -> AppConfig -> IO ()
runUp UpOptions {forMinutes} config = do
  let local = config {trustTier = LocalOperator}
  agents <- defaultAgentsDirectory
  exists <- doesDirectoryExist agents
  declarations <- if exists then fmap (agents </>) . sort . filter (".dhall" `isSuffixOf`) <$> listDirectory agents else pure []
  approvalsPath <- maybe defaultApprovalsPath pure config.localOperatorApprovalsFile
  approvals <- either (const emptyApprovals) id <$> loadLocalApprovals processCheckoutResolver approvalsPath
  stateDirectory <- maybe defaultStateDirectory pure config.localOperatorStateDirectory
  grants <- openGrantStore stateDirectory >>= either (const (pure [])) (\store -> either (const []) id <$> store.list)
  decided <- forM declarations \path ->
    loadAgent path >>= \case
      Left failure -> pure (Left ("skipped   " <> Text.pack path <> "   does not load: " <> Text.take 120 (Text.pack (show failure)) <> "; check with: shikigami-local doctor"))
      Right decl -> case decl.trigger of
        Schedule {cron} -> case parseCron (cronExpressionText cron) of
          Left problem -> pure (Left ("skipped   " <> agentNameText decl.name <> "   invalid schedule: " <> problem))
          Right schedule -> do
            granted <- grantedCheckout approvals grants decl
            pure case granted of
              Just (repository, checkout) -> Right (Armed path (agentNameText decl.name) schedule checkout, "armed     " <> agentNameText decl.name <> "   " <> cronExpressionText cron <> "   " <> repository)
              Nothing -> Left ("skipped   " <> agentNameText decl.name <> "   " <> cronExpressionText cron <> "   no stored approval; run once by hand: shikigami-local run " <> agentNameText decl.name <> " --in DIR")
        _ -> pure (Left ("skipped   " <> agentNameText decl.name <> "   manual trigger"))
  forM_ decided (TextIO.putStrLn . either id snd)
  let armed = [entry | Right (entry, _) <- decided]
  if null armed
    then TextIO.putStrLn "nothing is armed; nothing to do"
    else do
      started <- getCurrentTime
      fired <- newIORef Set.empty
      let deadline = (\minutes -> addUTCTime (fromIntegral (minutes * 60)) started) <$> forMinutes
          loop = do
            now <- getCurrentTime
            let minute = truncateToMinute now
            forM_ armed \entry -> do
              already <- Set.member (entry.name, minute) <$> readIORef fired
              when (isDue entry.cron minute && not already) do
                modifyIORef' fired (Set.insert (entry.name, minute))
                TextIO.putStrLn ("run       " <> entry.name <> "   " <> Text.pack (show minute))
                outcome <- try @SomeException (runAgentRun [] entry.path Nothing (Just entry.checkout) Nothing True Nothing local)
                either (\failure -> TextIO.putStrLn ("failed    " <> entry.name <> "   " <> Text.take 200 (Text.pack (show failure)))) (const (pure ())) outcome
            stop <- maybe (pure False) (\until' -> (> until') <$> getCurrentTime) deadline
            unless stop (threadDelay 15000000 >> loop)
      loop

-- | The repository of a stored grant that covers this exact declaration.
grantedCheckout :: LocalApprovals -> [LocalGrant] -> AgentDecl -> IO (Maybe (Text, FilePath))
grantedCheckout approvals grants decl = do
  matches <- forM [grant | grant <- grants, grant.agent == decl.name] \grant ->
    selectRepository processCheckoutResolver approvals (SelectByIdentity grant.repository) >>= \case
      Right repository | grantDigest decl repository == grant.digest -> pure (Just (repositoryIdText grant.repository, grant.source))
      _ -> pure Nothing
  pure (find (const True) [match | Just match <- matches])

truncateToMinute :: UTCTime -> UTCTime
truncateToMinute UTCTime {utctDay, utctDayTime} = UTCTime {utctDay, utctDayTime = fromIntegral (floor (utctDayTime / 60) * 60 :: Integer)}
