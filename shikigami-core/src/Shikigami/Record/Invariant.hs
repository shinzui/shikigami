-- | The kernel invariants, checked from one run's action record (EP-8 M3 of
-- MasterPlan 22).
--
-- 'checkRun' is pure: it reads the run's events in append order and the
-- few facts the record cannot hold about itself, and returns every
-- violation it finds. It knows the kinds the kernel owns (@run.admitted@,
-- @run.finished@, @authority.decided@, @authority.granted@). Any other kind
-- is an effect. An effect that names the action it performed (an @action@
-- and a @resource@, as @output.delivered@ does) is paired with the decision
-- that allowed it and with the journaled step it ran in. An effect that
-- names no action is counted in 'unlinkedEffects' so the gap is visible,
-- not silently passed.
--
-- K7 (observed content is evidence, never instruction) is a property of
-- how the kernel builds model input, not of the record; the check says so
-- instead of pretending to assert it.
module Shikigami.Record.Invariant
  ( RunFacts (..),
    InvariantViolation (..),
    invariantOf,
    renderViolation,
    RunCheck (..),
    checkRun,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.Workflow (WorkflowId (..))
import Shikigami.Record (RecordEvent (..), recordEntry, recordKindText)

-- | What the caller knows about the run besides its events.
data RunFacts = RunFacts
  { -- | The run being checked.
    run :: !WorkflowId,
    -- | Every run the record shows admitted under this run's idempotency
    -- key, this one included.
    keyAdmissions :: ![WorkflowId]
  }
  deriving stock (Eq, Show)

-- | One broken guarantee. Event positions count from 0 in append order.
data InvariantViolation
  = -- | K1: an event names no principal.
    MissingPrincipal !Int
  | -- | K1: the run acted for a second principal.
    PrincipalChanged !Int !Text !Text
  | -- | K1: the directory had paused or deactivated the principal at
    -- admission, yet an action was allowed or an effect happened.
    InactivePrincipalActed !Text !Int
  | -- | K2, K3: an effect with no earlier allowed decision for its exact
    -- action and resource.
    UndecidedEffect !Int !Text !Text !Text
  | -- | K4: no @run.admitted@ entry.
    MissingAdmission
  | -- | K4: the admission pins no declaration digest.
    MissingDeclarationDigest
  | -- | K5: the admission names neither a resource root nor a lease.
    UnboundedRun
  | -- | K6: an effect that names no journaled step.
    EffectOutsideStep !Int !Text
  | -- | K6: one effect key appears twice.
    RepeatedEffect !Text
  | -- | K8: more than one run admitted under one key.
    DuplicateAdmission ![WorkflowId]
  deriving stock (Eq, Show)

invariantOf :: InvariantViolation -> Text
invariantOf = \case
  MissingPrincipal {} -> "K1"
  PrincipalChanged {} -> "K1"
  InactivePrincipalActed {} -> "K1"
  UndecidedEffect {} -> "K2/K3"
  MissingAdmission -> "K4"
  MissingDeclarationDigest -> "K4"
  UnboundedRun -> "K5"
  EffectOutsideStep {} -> "K6"
  RepeatedEffect {} -> "K6"
  DuplicateAdmission {} -> "K8"

renderViolation :: InvariantViolation -> Text
renderViolation violation =
  invariantOf violation <> ": " <> case violation of
    MissingPrincipal at -> "event " <> showText at <> " names no principal"
    PrincipalChanged at admitted other -> "event " <> showText at <> " acts for " <> other <> ", not the admitted principal " <> admitted
    InactivePrincipalActed lifecycle at -> "the principal was " <> lifecycle <> " at admission, yet event " <> showText at <> " acted"
    UndecidedEffect at kind action resource -> "event " <> showText at <> " (" <> kind <> ") performed " <> action <> " " <> resource <> " with no earlier allowed decision"
    MissingAdmission -> "the record has no run.admitted entry"
    MissingDeclarationDigest -> "run.admitted pins no declaration digest"
    UnboundedRun -> "run.admitted names neither a resource root nor a lease"
    EffectOutsideStep at kind -> "event " <> showText at <> " (" <> kind <> ") names no journaled step"
    RepeatedEffect key -> "the effect " <> key <> " was recorded twice"
    DuplicateAdmission runs -> "the key admitted " <> showText (length runs) <> " runs: " <> Text.intercalate ", " ((.unWorkflowId) <$> runs)

-- | The result of one check: the violations, and how much of the record
-- the check could pair.
data RunCheck = RunCheck
  { events :: !Int,
    -- | Effects paired with a decision and a step.
    linkedEffects :: !Int,
    -- | Effect entries by kind that name no action, so no decision can be
    -- paired with them.
    unlinkedEffects :: ![(Text, Int)],
    violations :: ![InvariantViolation]
  }
  deriving stock (Eq, Show)

kernelKinds :: [Text]
kernelKinds = ["run.admitted", "run.finished", "authority.decided", "authority.granted"]

checkRun :: RunFacts -> [RecordEvent] -> RunCheck
checkRun RunFacts {keyAdmissions} recordEvents =
  RunCheck
    { events = length indexed,
      linkedEffects = length linked,
      unlinkedEffects = Map.toList (Map.fromListWith (+) [(kind, 1) | (_, kind, _) <- unlinked]),
      violations =
        principalViolations
          <> admissionViolations
          <> inactiveViolations
          <> decisionViolations
          <> stepViolations
          <> repeatViolations
          <> [DuplicateAdmission distinctAdmissions | length distinctAdmissions > 1]
    }
  where
    indexed = zip [0 :: Int ..] recordEvents
    kindOf RecordEvent {entry} = recordKindText (fst (recordEntry entry))
    payloadOf RecordEvent {entry} = snd (recordEntry entry)
    effects = [(i, kindOf event, payloadOf event) | (i, event) <- indexed, kindOf event `notElem` kernelKinds]
    linked = [(i, kind, action, resource, payload) | (i, kind, payload) <- effects, Just action <- [field "action" payload], Just resource <- [field "resource" payload]]
    unlinked = [effect | effect@(_, _, payload) <- effects, isNothing (field "action" payload) || isNothing (field "resource" payload)]
    admission = [(i, payloadOf event) | (i, event) <- indexed, kindOf event == "run.admitted"]

    -- K1
    -- The run acts for the principal of its first event that names one.
    admittedPrincipal = case [principal | (_, RecordEvent {principal}) <- indexed, not (Text.null principal)] of
      first' : _ -> Just first'
      [] -> Nothing
    principalViolations =
      [MissingPrincipal i | (i, RecordEvent {principal}) <- indexed, Text.null principal]
        <> [ PrincipalChanged i admitted principal
           | Just admitted <- [admittedPrincipal],
             (i, RecordEvent {principal}) <- indexed,
             not (Text.null principal),
             principal /= admitted
           ]
    inactiveViolations = case admission of
      (_, payload) : _
        | Just lifecycle <- field "lifecycle" payload,
          lifecycle `elem` ["paused", "deactivated"] ->
            [InactivePrincipalActed lifecycle i | (i, _) <- allowedDecisions] <> [InactivePrincipalActed lifecycle i | (i, _, _) <- effects]
      _ -> []

    -- K4, K5
    admissionViolations = case admission of
      [] -> [MissingAdmission]
      (_, payload) : _ ->
        [MissingDeclarationDigest | maybe True Text.null (field "declarationDigest" payload)]
          <> [UnboundedRun | isNothing (field "root" payload), not (positive "timeoutSeconds" payload)]

    -- K2, K3
    allowedDecisions =
      [ (i, (action, resource))
      | (i, event) <- indexed,
        kindOf event == "authority.decided",
        let payload = payloadOf event,
        field "decision" payload == Just "allowed",
        Just action <- [field "action" payload],
        Just resource <- [field "resource" payload]
      ]
    decisionViolations =
      [ UndecidedEffect i kind action resource
      | (i, kind, action, resource, _) <- linked,
        not (any (\(j, decided) -> j < i && decided == (action, resource)) allowedDecisions)
      ]

    -- K6
    stepViolations = [EffectOutsideStep i kind | (i, kind, _, _, payload) <- linked, maybe True Text.null (field "step" payload)]
    effectKeys = [kind <> " " <> key | (_, kind, _, resource, payload) <- linked, let key = maybe resource id (field "effectKey" payload)]
    repeatViolations = [RepeatedEffect key | (key, count) <- Map.toList (Map.fromListWith (+) [(key, 1 :: Int) | key <- effectKeys]), count > 1]

    -- K8
    distinctAdmissions = nub keyAdmissions

field :: Text -> Value -> Maybe Text
field name = \case
  Object object | Just (String value) <- KeyMap.lookup (Key.fromText name) object -> Just value
  _ -> Nothing

positive :: Text -> Value -> Bool
positive name = \case
  Object object | Just (Number value) <- KeyMap.lookup (Key.fromText name) object -> value > 0
  _ -> False

showText :: (Show a) => a -> Text
showText = Text.pack . show
