-- | The inventory's vocabulary and the verdict rule.
--
-- A /surface/ is something outside this repository's control may depend on: a
-- declaration schema, a command line, an exported module, a wire format. Each
-- has one owner, one stability level and one check. The types here mirror
-- @api-baseline/Surface.dhall@ constructor for constructor, so the inventory
-- decodes generically.
module ApiBaseline.Types
  ( Stability (..),
    Enforcement (..),
    Freeze (..),
    Check (..),
    Surface (..),
    Severity (..),
    Finding (..),
    Verdict (..),
    verdict,
    worstSeverity,
    stabilityText,
    policyText,
    renderFinding,
  )
where

import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (FromDhall)
import GHC.Generics (Generic)

-- | How much a consumer may rely on a surface.
data Stability = Stable | Provisional | Internal
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall)

-- | Whether a finding on the surface fails the check or is only reported.
data Enforcement = Report | Enforce
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall)

-- | Which of the two freezes pins the surface.
data Freeze = Declaration | Kernel
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall)

-- | How a surface is compared with its pin. Every path is relative to the
-- repository root.
data Check
  = -- | A Dhall schema: its semantic hash, and a corpus of declarations that
    -- must keep loading.
    DhallSchema {schema :: !Text, hash :: !Text, corpus :: !Text}
  | -- | The exported names of modules of one built component.
    ExportList {component :: !Text, modules :: ![Text], pinned :: !Text}
  | -- | The HTTP API description against a frozen copy.
    OpenApi {current :: !Text, frozen :: !Text}
  | -- | The @--help@ text of the listed verbs of one executable.
    CliHelp {executable :: !Text, verbs :: ![[Text]], goldens :: !Text}
  | -- | The journal encoding of each corpus declaration.
    JournalCodec {corpus :: !Text, goldens :: !Text}
  | -- | The durable workflow contract, through @just keiro-gate@.
    KeiroGate {since :: !Text}
  | -- | The modules a Cabal file's main library exposes or re-exports.
    ExposedSet {cabal :: !Text, pinned :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall)

data Surface = Surface
  { name :: !Text,
    owner :: !Text,
    stability :: !Stability,
    rule :: !Text,
    check :: !Check,
    freeze :: !Freeze,
    enforcement :: !Enforcement
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall)

-- | 'Changed' differs from the pin but obeys the surface's rule; 'Breaking'
-- does not obey it.
data Severity = Changed | Breaking
  deriving stock (Eq, Ord, Show)

data Finding = Finding
  { severity :: !Severity,
    detail :: !Text
  }
  deriving stock (Eq, Show)

-- | What a surface's findings mean for the run. Only 'Broken' fails it.
data Verdict = Clean | Drift !(NonEmpty Finding) | Broken !(NonEmpty Finding)
  deriving stock (Eq, Show)

-- | A report-only surface never fails the run, whatever it finds. An
-- enforcing surface fails on any finding: an additive change is deliberate
-- too, and is accepted by re-pinning.
verdict :: Enforcement -> [Finding] -> Verdict
verdict enforcement findings = case NonEmpty.nonEmpty findings of
  Nothing -> Clean
  Just found -> case enforcement of
    Report -> Drift found
    Enforce -> Broken found

worstSeverity :: [Finding] -> Maybe Severity
worstSeverity findings = if null findings then Nothing else Just (maximum (map (.severity) findings))

stabilityText :: Stability -> Text
stabilityText = \case
  Stable -> "stable"
  Provisional -> "provisional"
  Internal -> "internal"

-- | What a deliberate change to a surface of this level needs. The failure
-- message quotes it, so the reader learns the way forward where the check
-- stopped them.
policyText :: Stability -> Text -> [Text]
policyText stability surface = case stability of
  Stable ->
    [ "This surface is stable. A breaking change needs a new ADR, a compatibility path and a",
      "re-pin in the same commit; an additive change needs only the re-pin:",
      "  just api-baseline-pin " <> surface
    ]
  Provisional ->
    [ "This surface is provisional. A breaking change needs a Decision Log entry in its owning",
      "plan and an updated corpus in the same commit, then: just api-baseline-pin " <> surface
    ]
  Internal ->
    ["This surface is internal. It carries no promise; re-pin with: just api-baseline-pin " <> surface]

-- | One surface's findings as an operator reads them: what changed, the rule
-- it is held to, and the path for a deliberate change.
renderFinding :: Surface -> [Finding] -> Text
renderFinding surface findings =
  Text.unlines $
    [surface.name <> " (" <> stabilityText surface.stability <> "): " <> heading]
      <> concatMap describe findings
      <> ["  Rule: " <> surface.rule]
      <> map ("  " <>) (policyText surface.stability surface.name)
      <> ["  Policy: docs/architecture/api-baseline.md"]
  where
    heading = case worstSeverity findings of
      Just Breaking -> "BREAKING"
      _ -> "CHANGED"
    describe finding = case Text.lines finding.detail of
      [] -> []
      first : rest -> ("  " <> first) : map ("    " <>) rest
