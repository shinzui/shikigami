#!/usr/bin/env python3
"""Public parsers and views compile; sealed and opaque initiative values cannot be forged."""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PLAN = json.loads((ROOT / "dist-newstyle/cache/plan.json").read_text())
CORE_UNITS = [entry["id"] for entry in PLAN["install-plan"]
              if entry["pkg-name"] == "shikigami-core" and entry.get("component-name") == "lib"]
assert len(CORE_UNITS) == 1, CORE_UNITS
CORE_UNIT = CORE_UNITS[0]

HEADER = '''{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ImportQualifiedPost #-}
module InitiativeBoundary where
import Data.Aeson qualified as Aeson
import Data.Coerce (coerce)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics qualified as Generics
import Shikigami.Initiative.Types qualified as Initiative
import Shikigami.Objective.Keys qualified as Keys
'''

POSITIVE = '''
proposal :: Text -> Either Text Initiative.ProposalId
proposal = Initiative.parseProposalId

policy :: Text -> Either Text Initiative.StandingPolicyId
policy = Initiative.parseStandingPolicyId

newProposal :: IO Initiative.ProposalId
newProposal = Initiative.newProposalId

excerpt :: Text -> Either Text Initiative.Excerpt
excerpt = Initiative.parseExcerpt

digest :: Initiative.Excerpt -> Initiative.ExcerptDigest
digest = Initiative.excerptDigestFor

candidateFacts :: Initiative.Candidate -> Initiative.CandidateFacts
candidateFacts = Initiative.candidateFacts

assessmentFacts :: Initiative.Assessment -> Initiative.AssessmentFacts
assessmentFacts = Initiative.assessmentFacts

assessmentView :: Initiative.Assessment -> Initiative.AssessmentView
assessmentView = Initiative.assessmentView

candidateView :: UTCTime -> Initiative.Candidate -> Initiative.CandidateView
candidateView = Initiative.candidateView

proposalView :: Initiative.Proposal -> Initiative.ProposalView
proposalView = Initiative.proposalView

proposalJson :: Initiative.ProposalView -> Aeson.Value
proposalJson = Aeson.toJSON

ref :: Text -> Either Text Keys.ProposalRef
ref = Keys.parseProposalRef
'''

REFUSALS = [
    ('ProposalId constructor', 'bypass = Initiative.ProposalId'),
    ('ProposalId coercion', 'bypass :: Text -> Initiative.ProposalId\nbypass = coerce'),
    ('ProposalId generic', 'bypass :: Initiative.ProposalId -> Generics.Rep Initiative.ProposalId ()\nbypass = Generics.from'),
    ('StandingPolicyId constructor', 'bypass = Initiative.StandingPolicyId'),
    ('StandingPolicyId coercion', 'bypass :: Text -> Initiative.StandingPolicyId\nbypass = coerce'),
    ('Candidate constructor', 'bypass = Initiative.Candidate'),
    ('Candidate coercion', 'bypass :: Initiative.CandidateFacts -> Initiative.Candidate\nbypass = coerce'),
    ('Candidate generic', 'bypass :: Initiative.Candidate -> Generics.Rep Initiative.Candidate ()\nbypass = Generics.from'),
    ('Candidate decoded', 'bypass :: Aeson.Value -> Aeson.Result Initiative.Candidate\nbypass = Aeson.fromJSON'),
    ('Assessment constructor', 'bypass = Initiative.Assessment'),
    ('Assessment coercion', 'bypass :: Initiative.AssessmentFacts -> Initiative.Assessment\nbypass = coerce'),
    ('Assessment generic', 'bypass :: Initiative.Assessment -> Generics.Rep Initiative.Assessment ()\nbypass = Generics.from'),
    ('Assessment decoded', 'bypass :: Aeson.Value -> Aeson.Result Initiative.Assessment\nbypass = Aeson.fromJSON'),
    ('Assessment from view', 'bypass :: Initiative.AssessmentView -> Initiative.Assessment\nbypass = coerce'),
    ('Assessment seal is not public', 'bypass = Initiative.sealAssessment'),
    ('Excerpt constructor', 'bypass = Initiative.Excerpt'),
    ('Excerpt coercion', 'bypass :: Text -> Initiative.Excerpt\nbypass = coerce'),
    ('Excerpt decoded', 'bypass :: Aeson.Value -> Aeson.Result Initiative.Excerpt\nbypass = Aeson.fromJSON'),
    ('Confidence coercion', 'bypass :: Double -> Initiative.Confidence\nbypass = coerce'),
    ('OutcomeText coercion', 'bypass :: Text -> Initiative.OutcomeText\nbypass = coerce'),
    ('CriterionText coercion', 'bypass :: Text -> Initiative.CriterionText\nbypass = coerce'),
    ('InitiativeLimit coercion', 'bypass :: Int -> Initiative.InitiativeLimit "page"\nbypass = coerce'),
    ('InitiativeLimit scope substitution', 'bypass :: Initiative.InitiativeLimit "page" -> Initiative.InitiativeLimit "other"\nbypass = coerce'),
    ('ProposalKey coercion', 'bypass :: Text -> Initiative.ProposalKey\nbypass = coerce'),
    ('ProposalRef constructor', 'bypass = Keys.ProposalRef'),
    ('ActionClass cannot publish', 'bypass = Initiative.PublishPullRequest'),
]

with tempfile.TemporaryDirectory(prefix='shikigami-initiative-types-') as directory:
    source = Path(directory) / 'InitiativeBoundary.hs'

    def compile_client(body):
        source.write_text(HEADER + body + '\n')
        return subprocess.run(
            ['cabal', 'exec', '--', 'ghc', '-fno-code', '-package-id', CORE_UNIT, str(source)],
            cwd=ROOT, capture_output=True, text=True, timeout=120)

    result = compile_client(POSITIVE)
    assert result.returncode == 0, (result.stdout, result.stderr)
    print('initiative boundary: public factories and views: passed', flush=True)
    for label, body in REFUSALS:
        result = compile_client(body)
        assert result.returncode != 0, label
        assert 'Could not find module' not in result.stderr and 'hidden package' not in result.stderr, (label, result.stderr)
        print(f'initiative boundary: {label} refused: passed', flush=True)
