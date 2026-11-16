{-# LANGUAGE DataKinds #-}

-- | Operator verbs over unrequested work, as one admin verb. Reads need the
-- database and reveal no excerpt, because the ledger stores none. Installing
-- or revoking a standing policy and pruning act as the configured local
-- operator.
--
-- The verb is written against 'AdminContext' and names no process
-- configuration, so it moves with its use case (docs/adr/0129).
module FlowPack.Initiative.Command
  ( proposalsVerb,
  )
where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.ByteString.Lazy.Char8 qualified as Char8
import Data.Text qualified as Text
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Effectful (Eff)
import FlowPack.Initiative.Inspection (anyExhausted, inspect)
import FlowPack.Initiative.Ledger (listCandidates, listProposals, pruneCandidatesBefore)
import FlowPack.Initiative.Policy
import FlowPack.Initiative.Setting (initiativeSettingsFrom)
import FlowPack.Initiative.Settings (InitiativeSettings (..), defaultMaximumPolicyLifetime)
import FlowPack.Initiative.Types (parseProposalId, parseStandingPolicyId)
import Hasql.Transaction (Transaction)
import Kiroku.Store.Transaction (runTransaction)
import Options.Applicative
import Shikigami.Activity.Coordinate (activityCoordinate)
import Shikigami.Agent.Principal (mkAgentPrincipal)
import Shikigami.App (AppEffects)
import Shikigami.Objective.Types (ObjectiveSettings (..), OperatorId)
import Shikigami.Pack.Sdk (AdminContext (..), AdminVerb (..))
import Shikigami.Prelude hiding (argument, (.=))
import Shikigami.StateRevision (parseRevision)
import System.Exit (die, exitFailure)
import System.IO (IOMode (ReadMode), withBinaryFile)

-- | Read and govern unrequested work. A standing policy is the one way past a
-- person, so its verbs are here rather than anywhere an agent could reach.
proposalsVerb :: AdminVerb
proposalsVerb =
  AdminVerb
    { name = "proposals",
      parser = info (subparser commands <**> helper) (progDesc "Read proposals, candidates and admissions, and install or revoke standing policies")
    }
  where
    commands =
      command "policy" policyInfo
        <> command "list" (info (list <**> helper) (progDesc "Page through proposals"))
        <> command "inspect" (info (inspecting <**> helper) (progDesc "Show observer and policy usage with exhaustion explicit"))
        <> command "candidates" (info (candidates <**> helper) (progDesc "Page through an observer's recorded candidates"))
        <> command "admissions" (info (admissions <**> helper) (progDesc "Page through admissions pinned to their policy digests"))
        <> command "prune" (info (pruning <**> helper) (progDesc "Delete terminal skips older than an instant, a batch at a time"))
    json = switch (long "json")
    limit = option auto (long "limit" <> value 50 <> metavar "N")
    after = optional (strOption (long "after" <> metavar "CURSOR"))
    list = runProposalsList <$> optional (strOption (long "principal" <> metavar "PRINCIPAL")) <*> optional (strOption (long "status" <> metavar "STATUS")) <*> after <*> limit <*> json
    inspecting = runProposalsInspect <$> json <*> switch (long "fail-when-exhausted")
    candidates = runProposalsCandidates <$> strOption (long "principal" <> metavar "PRINCIPAL") <*> optional (option instant (long "since" <> metavar "ISO8601")) <*> after <*> limit <*> json
    admissions = runProposalsAdmissions <$> optional (strOption (long "policy" <> metavar "POLICY")) <*> after <*> limit <*> json
    pruning = runProposalsPrune <$> option instant (long "before" <> metavar "ISO8601") <*> option auto (long "batch" <> value 1000 <> metavar "N") <*> json
    instant = maybeReader iso8601ParseM

policyInfo :: ParserInfo (AdminContext -> IO ())
policyInfo = info (subparser commands <**> helper) (progDesc "Install, revoke and list standing policies as the configured operator")
  where
    commands =
      command "install" (info (installing <**> helper) (progDesc "Validate and install a new policy; a changed policy is a new policy"))
        <> command "revoke" (info (revoking <**> helper) (progDesc "Stop new admissions at once; admitted work continues"))
        <> command "list" (info (listing <**> helper) (progDesc "Page through policies with their live, revoked or expired state"))
    json = switch (long "json")
    installing = runPolicyInstall <$> strOption (long "file" <> metavar "FILE") <*> json
    revoking = runPolicyRevoke <$> strArgument (metavar "POLICY") <*> option auto (long "expected-revision" <> metavar "N") <*> json
    listing = runPolicyList <$> optional (strOption (long "principal" <> metavar "PRINCIPAL")) <*> optional (strOption (long "after" <> metavar "POLICY")) <*> option auto (long "limit" <> value 50 <> metavar "N") <*> json

runPolicyInstall :: FilePath -> Bool -> AdminContext -> IO ()
runPolicyInstall path _json context = do
  input <- readPolicyDocument path
  operator <- requireOperator context
  instant <- getCurrentTime
  declarations <- context.declarations
  active <- context.principalActive input.principal
  let policyContext =
        PolicyContext
          { principalActive = const active,
            objectives = context.objectives,
            catalog = context.repositories,
            declarations,
            now = instant,
            maximumLifetime = maybe defaultMaximumPolicyLifetime (.maximumPolicyLifetime) (initiativeSettingsFrom context.settings)
          }
  withLedger context (installPolicy operator policyContext input) >>= \case
    Left refusal -> die ("proposals policy install refused: " <> Text.unpack (policyRefusalText refusal))
    Right policy -> emit (policyView instant policy)

runPolicyRevoke :: Text -> Integer -> Bool -> AdminContext -> IO ()
runPolicyRevoke raw expected _json context = do
  policy <- checked (parseStandingPolicyId raw)
  revision <- checked (parseRevision expected)
  operator <- requireOperator context
  instant <- getCurrentTime
  withLedger context (revokePolicy operator policy revision instant) >>= \case
    Left refusal -> die ("proposals policy revoke refused: " <> Text.unpack (policyRefusalText refusal))
    Right view -> emit view

runPolicyList :: Maybe Text -> Maybe Text -> Int -> Bool -> AdminContext -> IO ()
runPolicyList claimed after limit _json context = do
  observer <- traverse (checked . mkAgentPrincipal) claimed
  cursor <- traverse (checked . parseStandingPolicyId) after
  instant <- getCurrentTime
  reading context (listPolicies instant observer cursor limit) >>= \case
    Left refusal -> die ("proposals policy list refused: " <> Text.unpack (policyRefusalText refusal))
    Right views -> emit views

runProposalsList :: Maybe Text -> Maybe Text -> Maybe Text -> Int -> Bool -> AdminContext -> IO ()
runProposalsList claimed status after limit _json context = do
  observer <- traverse (checked . mkAgentPrincipal) claimed
  cursor <- traverse (checked . parseProposalId) after
  forM_ status \wanted -> unless (wanted `elem` ["pending", "accepted", "admitted", "rejected", "expired", "refused"]) (die "unknown proposal status")
  reading context (listProposals observer status cursor limit) >>= \case
    Left problem -> die ("proposals list refused: " <> show problem)
    Right views -> emit views

runProposalsInspect :: Bool -> Bool -> AdminContext -> IO ()
runProposalsInspect _json failWhenExhausted context = do
  instant <- getCurrentTime
  reading context (inspect (initiativeSettingsFrom context.settings) instant) >>= \case
    Left refusal -> die ("proposals inspect refused: " <> Text.unpack (policyRefusalText refusal))
    Right view -> do
      emit view
      when (failWhenExhausted && anyExhausted view) exitFailure

runProposalsCandidates :: Text -> Maybe UTCTime -> Maybe Text -> Int -> Bool -> AdminContext -> IO ()
runProposalsCandidates claimed since after limit _json context = do
  observer <- checked (mkAgentPrincipal claimed)
  reading context (listCandidates observer since (activityCoordinate <$> after) limit) >>= emit

runProposalsAdmissions :: Maybe Text -> Maybe Text -> Int -> Bool -> AdminContext -> IO ()
runProposalsAdmissions policy after limit _json context = do
  named <- traverse (checked . parseStandingPolicyId) policy
  cursor <- traverse (checked . parseProposalId) after
  reading context (listAdmissions named cursor limit) >>= emit

runProposalsPrune :: UTCTime -> Int -> Bool -> AdminContext -> IO ()
runProposalsPrune before batch _json context = do
  _ <- requireOperator context
  removed <- reading context (pruneCandidatesBefore before batch)
  emit (object ["removed" .= removed])

requireOperator :: AdminContext -> IO OperatorId
requireOperator context =
  maybe (die "this command requires a configured local operator identity") pure context.objectives.operator

reading :: AdminContext -> Transaction value -> IO value
reading context transaction = withLedger context (runTransaction transaction)

withLedger :: AdminContext -> Eff AppEffects value -> IO value
withLedger AdminContext {runStore} action =
  runStore action >>= either (const (die "the proposal ledger is unavailable")) pure

readPolicyDocument :: FilePath -> IO PolicyInput
readPolicyDocument path = withBinaryFile path ReadMode \handle -> do
  bytes <- Lazy.hGet handle 1048577
  when (Lazy.length bytes > 1048576) (die "policy document exceeds 1 MiB")
  either (\problem -> die ("invalid standing policy document: " <> problem)) pure (Aeson.eitherDecode bytes)

emit :: (ToJSON value) => value -> IO ()
emit = Char8.putStrLn . Aeson.encode

checked :: Either Text value -> IO value
checked = either (die . Text.unpack) pure
