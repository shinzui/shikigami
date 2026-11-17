-- | Where a run's result goes: the kernel's output contract (EP-8 M2 of
-- MasterPlan 22).
--
-- A declaration lists outputs by kind with a JSON configuration; a
-- composition registers an adapter per kind and may name a default output.
-- A declaration that lists none receives the composition's default, resolved
-- once at admission and journaled, so a restart under another composition
-- keeps the run's destination. The declaration itself still says "no
-- outputs", which keeps it portable.
--
-- An adapter delivers inline, inside the run's own journaled step (the local
-- report), or through the kernel's outbox (plan 135, M3): the run journals and
-- enqueues an intent, and the publisher dispatches it with fresh checks and a
-- delivery receipt. Every Kikan service is delivered the second way.
module Shikigami.Output
  ( OutputKind,
    mkOutputKind,
    outputKindText,
    OutputDecl (..),
    OutputDelivery (..),
    OutputReceipt (..),
    OutputAdapter (..),
    OutputRoute (..),
    inlineOutputAdapter,
    outboxRouteOf,
    DefaultOutput (..),
    OutputRegistry,
    mkOutputRegistry,
    emptyOutputRegistry,
    registeredKinds,
    lookupAdapter,
    OutputLoadError (..),
    renderOutputLoadError,
    validateOutputs,
    ResolvedOutputs (..),
    resolveOutputs,
    resolvedOutputList,
    renderResolvedOutputs,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.List (find, nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Dhall (FromDhall (..))
import Dhall qualified
import GHC.Generics (Generic)
import Keiro.Workflow (WorkflowId)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Authority (OutputKind, mkOutputKind, outputKindText)
import Shikigami.Sink.Types (OutboxRoute)

-- | One output a declaration lists: its kind and the adapter's configuration.
data OutputDecl = OutputDecl
  { kind :: !OutputKind,
    config :: !Value
  }
  deriving stock (Eq, Show, Generic)

-- | What an adapter delivers.
data OutputDelivery = OutputDelivery
  { run :: !WorkflowId,
    agent :: !AgentName,
    -- | The output's position in the resolved list.
    ordinal :: !Int,
    output :: !OutputDecl,
    -- | The behavior's result.
    result :: !Value
  }

-- | What delivery produced, journaled with the run.
data OutputReceipt = OutputReceipt
  { kind :: !Text,
    location :: !Text,
    detail :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data OutputAdapter = OutputAdapter
  { kind :: !OutputKind,
    validate :: !(Value -> Either Text ()),
    route :: !OutputRoute
  }

-- | How an adapter delivers.
data OutputRoute
  = -- | In the run's @deliver-outputs@ step. Must be idempotent for one run
    -- and ordinal: delivery is a replayed step.
    DeliverInline !(OutputDelivery -> IO (Either Text OutputReceipt))
  | -- | Through the outbox, by the publisher.
    DeliverByOutbox !OutboxRoute

inlineOutputAdapter :: OutputKind -> (Value -> Either Text ()) -> (OutputDelivery -> IO (Either Text OutputReceipt)) -> OutputAdapter
inlineOutputAdapter kind validate deliver = OutputAdapter {kind, validate, route = DeliverInline deliver}

outboxRouteOf :: OutputAdapter -> Maybe OutboxRoute
outboxRouteOf adapter = case adapter.route of
  DeliverByOutbox route -> Just route
  DeliverInline _ -> Nothing

data DefaultOutput = NoDefaultOutput | DefaultOutput !OutputDecl

-- | Sealed: adapters by unique kind and a default whose adapter accepts it.
data OutputRegistry = OutputRegistry ![OutputAdapter] !DefaultOutput

mkOutputRegistry :: [OutputAdapter] -> DefaultOutput -> Either Text OutputRegistry
mkOutputRegistry adapters defaultOutput
  | length (nub kinds) /= length kinds = Left "two output adapters register the same kind"
  | DefaultOutput decl <- defaultOutput = case find (\adapter -> adapter.kind == decl.kind) adapters of
      Nothing -> Left ("the default output kind " <> outputKindText decl.kind <> " is not registered")
      Just adapter -> either (\problem -> Left ("the default output is invalid: " <> problem)) (const (Right (OutputRegistry adapters defaultOutput))) (adapter.validate decl.config)
  | otherwise = Right (OutputRegistry adapters defaultOutput)
  where
    kinds = (.kind) <$> adapters

emptyOutputRegistry :: OutputRegistry
emptyOutputRegistry = OutputRegistry [] NoDefaultOutput

registeredKinds :: OutputRegistry -> [OutputKind]
registeredKinds (OutputRegistry adapters _) = (.kind) <$> adapters

lookupAdapter :: OutputRegistry -> OutputKind -> Maybe OutputAdapter
lookupAdapter (OutputRegistry adapters _) kind = find (\adapter -> adapter.kind == kind) adapters

data OutputLoadError
  = UnregisteredOutputKind !OutputKind ![OutputKind]
  | InvalidOutputConfig !OutputKind !Text
  deriving stock (Eq, Show)

renderOutputLoadError :: OutputLoadError -> Text
renderOutputLoadError = \case
  UnregisteredOutputKind kind registered -> "output kind " <> outputKindText kind <> " is not registered here (registered: " <> (if null registered then "none" else Text.intercalate ", " (outputKindText <$> registered)) <> ")"
  InvalidOutputConfig kind problem -> "output " <> outputKindText kind <> ": " <> problem

-- | Every listed output names a registered kind its adapter accepts.
validateOutputs :: OutputRegistry -> [OutputDecl] -> Either (NonEmpty OutputLoadError) ()
validateOutputs registry decls = case concatMap check decls of
  [] -> Right ()
  first' : rest -> Left (first' :| rest)
  where
    check decl = case lookupAdapter registry decl.kind of
      Nothing -> [UnregisteredOutputKind decl.kind (registeredKinds registry)]
      Just adapter -> either (\problem -> [InvalidOutputConfig decl.kind problem]) (const []) (adapter.validate decl.config)

data ResolvedOutputs
  = -- | The declaration's own list always wins.
    DeclaredOutputs !(NonEmpty OutputDecl)
  | -- | The declaration listed none; the composition's default applies.
    CompositionDefault !OutputDecl
  | -- | None declared and the composition has no default: the result stays
    -- in the journal and the session.
    JournalOnly
  deriving stock (Eq, Show, Generic)

resolveOutputs :: OutputRegistry -> [OutputDecl] -> ResolvedOutputs
resolveOutputs (OutputRegistry _ defaultOutput) = \case
  first' : rest -> DeclaredOutputs (first' :| rest)
  [] -> case defaultOutput of
    DefaultOutput decl -> CompositionDefault decl
    NoDefaultOutput -> JournalOnly

resolvedOutputList :: ResolvedOutputs -> [OutputDecl]
resolvedOutputList = \case
  DeclaredOutputs decls -> foldr (:) [] decls
  CompositionDefault decl -> [decl]
  JournalOnly -> []

renderResolvedOutputs :: ResolvedOutputs -> Text
renderResolvedOutputs = \case
  DeclaredOutputs decls -> Text.intercalate ", " (outputKindText . (.kind) <$> foldr (:) [] decls)
  CompositionDefault decl -> outputKindText decl.kind <> " (composition default)"
  JournalOnly -> "none (the result stays in the journal)"

instance ToJSON OutputDecl where
  toJSON OutputDecl {kind, config} = Aeson.object ["kind" .= kind, "config" .= config]

instance FromJSON OutputDecl where
  parseJSON = Aeson.withObject "OutputDecl" \fields -> OutputDecl <$> fields .: "kind" <*> fields .: "config"

instance ToJSON ResolvedOutputs

instance FromJSON ResolvedOutputs

-- | Dhall: @{ kind : Text, config : Text }@ with the configuration as JSON text.
instance FromDhall OutputDecl where
  autoWith _ =
    let Dhall.Decoder {extract = readBase, expected} = Dhall.record ((,) <$> Dhall.field "kind" Dhall.strictText <*> Dhall.field "config" Dhall.strictText)
     in Dhall.Decoder
          { extract = \expression -> case Dhall.toMonadic (readBase expression) of
              Left problem -> Dhall.fromMonadic (Left problem)
              Right (kindText, configText) -> case (mkOutputKind kindText, Aeson.eitherDecodeStrict (Text.Encoding.encodeUtf8 configText)) of
                (Left problem, _) -> Dhall.extractError problem
                (_, Left problem) -> Dhall.extractError ("output " <> kindText <> " config is not JSON: " <> Text.pack problem)
                (Right kind, Right config) -> pure OutputDecl {kind, config},
            expected
          }
