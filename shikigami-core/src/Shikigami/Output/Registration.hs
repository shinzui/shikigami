-- | Output kinds a pack registers (plan 135, M3).
--
-- The kernel owns the output port ("Shikigami.Output"); a pack that knows a
-- service contributes an 'OutputRegistration' per kind it delivers. A
-- registration validates a configuration without any service (so a
-- declaration can be checked by any command), names the configuration its
-- kind takes as a composition's default output, and builds its adapter once,
-- at start, from the validated settings of the composed packs.
module Shikigami.Output.Registration
  ( AdapterContext (..),
    OutputRegistration (..),
    DefaultOutputChoice (..),
    parseDefaultOutputChoice,
    renderDefaultOutputChoice,
    validationRegistry,
    buildOutputRegistry,
  )
where

import Data.Aeson (Value (Null))
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.Authority (OutputKind, outputKindText)
import Shikigami.Log (Logger)
import Shikigami.Output
import Shikigami.Pack.Setting (PackSettings)
import Shikigami.Sink.Http (HttpLimits)
import Shikigami.Sink.Types (OutboxRoute (..), SinkOutcome (..))

-- | What a pack's adapters are built from.
data AdapterContext = AdapterContext
  { logger :: !Logger,
    -- | The validated settings of every composed pack.
    settings :: !PackSettings,
    -- | The deployment's HTTP request and response bounds.
    httpLimits :: !HttpLimits
  }

data OutputRegistration = OutputRegistration
  { kind :: !OutputKind,
    -- | Accept a configuration, with no service at hand.
    validate :: !(Value -> Either Text ()),
    -- | The configuration this kind takes as the composition's default
    -- output, if it can be one.
    defaultConfig :: !(Maybe Value),
    -- | Whether a composition that names no default takes this kind.
    preferredDefault :: !Bool,
    -- | Build the adapter. A 'Left' refuses to start and names what is
    -- missing or invalid, never a secret.
    build :: !(AdapterContext -> IO (Either Text OutputAdapter))
  }

-- | The default output a choice selects among the registrations.
chooseDefault :: [OutputRegistration] -> DefaultOutputChoice -> Either Text DefaultOutput
chooseDefault registrations = \case
  NoDefault -> Right NoDefaultOutput
  CompositionPreferred -> case [registration | registration <- registrations, registration.preferredDefault] of
    [] -> Right NoDefaultOutput
    [registration] -> fromRegistration registration
    _ -> Left "more than one composed pack prefers its output as the default"
  DefaultKind kind -> case find (\registration -> registration.kind == kind) registrations of
    Nothing -> Left ("the default output kind " <> outputKindText kind <> " is not registered here")
    Just registration -> fromRegistration registration
  where
    fromRegistration registration = case registration.defaultConfig of
      Nothing -> Left ("output kind " <> outputKindText registration.kind <> " cannot be a default output")
      Just config -> Right (DefaultOutput OutputDecl {kind = registration.kind, config})

-- | A registry for checking declarations only: each kind validates its
-- configuration, and none can deliver. @builtins@ are adapters the
-- composition always has (the local report, say).
validationRegistry :: [OutputAdapter] -> [OutputRegistration] -> DefaultOutputChoice -> Either Text OutputRegistry
validationRegistry builtins registrations choice = do
  defaultOutput <- chooseDefault registrations choice
  mkOutputRegistry (builtins <> (checking <$> registrations)) defaultOutput
  where
    checking registration =
      OutputAdapter
        { kind = registration.kind,
          validate = registration.validate,
          route =
            DeliverByOutbox
              OutboxRoute
                { address = const Null,
                  target = \_ _ -> Left "this composition only validates outputs",
                  dispatch = \_ -> pure (Failed "this composition only validates outputs")
                }
        }

-- | Build every registered adapter, then the registry.
buildOutputRegistry :: AdapterContext -> [OutputAdapter] -> [OutputRegistration] -> DefaultOutputChoice -> IO (Either Text OutputRegistry)
buildOutputRegistry context builtins registrations choice = do
  built <- traverse (\registration -> registration.build context) registrations
  pure do
    adapters <- sequence built
    defaultOutput <- chooseDefault registrations choice
    mkOutputRegistry (builtins <> adapters) defaultOutput
