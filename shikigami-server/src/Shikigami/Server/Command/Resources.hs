-- | Bounded, payload-free resource inspection for operators.
module Shikigami.Server.Command.Resources (runResourcesInspect, resourceView) where

import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (runStoreIO)
import Shikigami.App.Config (AppConfig, revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Execution.Quantity (zeroAmount)
import Shikigami.Execution.Resources
import Shikigami.Execution.ResourcesStore (inspectRoot)
import Shikigami.Migrations (verifyShikigamiMigrations)
import System.Exit (die)

runResourcesInspect :: ExecutionRootId -> Bool -> AppConfig -> IO ()
runResourcesInspect key _asJson config = do
  connection <- revealSecretText <$> requireDatabaseUrl "resources inspect" config
  verifyShikigamiMigrations connection
  withStore (defaultConnectionSettings connection) \store -> do
    result <- runStoreIO store (inspectRoot key)
    case result of
      Left _ -> die "resource store is unavailable"
      Right (Left _) -> die "resource root was not found"
      Right (Right root) -> do
        now <- getCurrentTime
        Lazy.putStrLn (encode (object ["rootId" .= key, "resources" .= resourceView now root]))

resourceView :: UTCTime -> Root -> Value
resourceView now root =
  object
    [ "envelope" .= root.envelope,
      "revision" .= root.revision,
      "settled" .= root.usage.settled,
      "heldIncludingAllocations" .= root.usage.held,
      "measuredUsage" .= root.known,
      "activeAttempts" .= root.active,
      "unknownAttempts" .= root.unknown,
      "activeLimit" .= root.activeLimit,
      "units" .= object ["CostMicroUsd" .= ("millionths of one USD" :: Text), "Tokens" .= ("tokens" :: Text)],
      "refusalCategories"
        .= ( [RootCancelled | root.cancelled == StopWork]
               <> [OverageRecorded | root.overage == OverageDetected]
               <> [CutoffReached | now >= root.envelope.cutoff]
               <> either (\err -> [err]) (\usage -> [ResourceExhausted d | (d, Limited n) <- Map.toList (effectiveLimits root), Map.findWithDefault zeroAmount d usage >= n]) (occupied root.usage)
               <> [DimensionNotAdmitted d | d <- [minBound .. maxBound], Map.notMember d root.envelope.limits]
           )
    ]
