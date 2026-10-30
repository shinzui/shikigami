-- | Service-owned interpreter over the released Kioku effect row. Long-running
-- roles bind their already acquired store; standalone actions may acquire one.
module Shikigami.App
  ( AppEnv (..),
    AppEffects,
    CommandEffects,
    commandOptions,
    runAppIO,
    noopTracer,
  )
where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Effectful (Eff, runEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import Effectful.Reader.Static (Reader, ask, runReader)
import GHC.Generics (Generic)
import Keiro.Command (RunCommandOptions (..), defaultRunCommandOptions)
import Keiro.Telemetry (KeiroMetrics)
import Kioku.App qualified as Kioku
import Kiroku.Store.Connection (ConnectionSettings, KirokuStore)
import Kiroku.Store.Effect (runStoreResource)
import Kiroku.Store.Effect.Resource (runKirokuStoreWith, withKirokuStore)
import Kiroku.Store.Error (StoreError)
import Shibuya.Telemetry.Effect (Tracer, runTracing)

type AppEffects = Reader RunCommandOptions ': Kioku.AppEffects

type CommandEffects es = Reader RunCommandOptions :> es

data AppEnv = AppEnv
  { connectionSettings :: !ConnectionSettings,
    tracer :: !Tracer,
    metrics :: !(Maybe KeiroMetrics),
    store :: !(Maybe KirokuStore)
  }
  deriving stock (Generic)

commandOptions :: (CommandEffects es) => Eff es RunCommandOptions
commandOptions = ask

runAppIO :: AppEnv -> Eff AppEffects a -> IO (Either StoreError a)
runAppIO env action =
  runEff . runTracing env.tracer . runErrorNoCallStack $
    case env.store of
      Nothing -> withKirokuStore env.connectionSettings interpreted
      Just acquired -> runKirokuStoreWith acquired interpreted
  where
    options = defaultRunCommandOptions & #tracer .~ Just env.tracer & #metrics .~ env.metrics
    interpreted = runStoreResource (runReader options action)

noopTracer :: IO Tracer
noopTracer = Kioku.noopTracer
