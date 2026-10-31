#!/usr/bin/env python3
"""Positive public factories first; generic APIs must not bypass opaque owners."""
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
HEADER = '''{-# LANGUAGE ImportQualifiedPost #-}
module OpaqueBoundary where
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.Coerce (coerce)
import Data.ByteString (ByteString)
import Data.Text (Text)
import GHC.Generics qualified as Generic
import Shikigami.Agent.Decl (AgentDecl)
import Shikigami.Agent.Principal qualified as Principal
import Shikigami.App.Config qualified as Config
import Shikigami.Attestation.Reviewed qualified as Reviewed
import Shikigami.Capability.Overlay qualified as Overlay
import Shikigami.Execution.Claim qualified as Claim
import Shikigami.Execution.AssignmentKey qualified as Assignment
import Shikigami.Execution.ToolPosition qualified as Position
import Shikigami.Decision.Contract qualified as Decision
import Shikigami.Log.Correlation qualified as Correlation
import Shikigami.PracticeReview.Evidence qualified as Evidence
import Shikigami.Router.Declaration qualified as Declaration
import Shikigami.Workspace.Instructions qualified as Instructions
import Shikigami.Inspection.Settings qualified as Inspection
import Shikigami.Repository qualified as Repository
import Shikigami.Router.Decision qualified as Router
import Shikigami.Sink.Auth qualified as Auth
'''
POSITIVE = '''principal :: Text -> Either Text Principal.AgentPrincipal
principal = Principal.mkAgentPrincipal
port :: Int -> Either Text Config.Port
port = Config.mkPort
bytes :: Int -> Either Text Config.ByteLimit
bytes = Config.mkByteLimit
secret :: Config.SecretText -> Text
secret = Config.revealSecretText
commit :: Text -> Either Text Reviewed.FullCommit
commit = Reviewed.mkFullCommit
capability :: Text -> Either Overlay.CapabilityIdError Overlay.CapabilityId
capability = Overlay.mkCapabilityId
capabilityRevision :: Text -> Either Overlay.CapabilityRevisionError Overlay.CapabilityRevision
capabilityRevision = Overlay.mkCapabilityRevision
emptyCapabilities :: Overlay.ResolvedCapabilitySet
emptyCapabilities = Overlay.emptyResolvedCapabilitySet
inspection :: Inspection.InspectionCredential -> Text
inspection = Inspection.revealInspectionCredential
revision :: Text -> Either Text Repository.Revision
revision = Repository.mkRevision
path :: Text -> Either Text Repository.RelativePath
path = Repository.mkRelativePath
route :: Router.ValidatedRouteDecision -> Router.RouteDecision
route = Router.validatedRouteDecision
bearer :: Auth.BearerToken -> ByteString -> Bool
bearer = Auth.matchesBearerHeader
failure :: Decision.FailureCode -> Text -> Decision.DecisionFailure
failure = Decision.decisionFailure
claimOwner :: Text -> Either Text Claim.ClaimOwner
claimOwner = Claim.parseClaimOwner
assignment :: Text -> Either Text Assignment.AssignmentKey
assignment = Assignment.parseAssignmentKey
position :: Integer -> Either Text Position.ToolPosition
position = Position.parseToolPosition
run :: Text -> Correlation.RunCorrelationId
run = Correlation.runCorrelationId
call :: Correlation.RunCorrelationId -> Text -> Int -> Correlation.CallCorrelationId
call = Correlation.callCorrelationId
bundle :: Int -> Text -> Text -> [(Text, Text)] -> Either Instructions.InstructionError Instructions.InstructionBundle
bundle = Instructions.mkInstructionBundle
router :: AgentDecl -> Either [Declaration.RouterDeclarationError] Declaration.ValidatedRouterDeclaration
router = Declaration.validateRouterDeclaration
routerView :: Declaration.ValidatedRouterDeclaration -> Declaration.RouterDeclarationView
routerView = Declaration.validatedRouterDeclaration
pin :: Evidence.EvidenceLimits -> Repository.RepositoryId -> Repository.Revision -> Repository.Revision -> Maybe Repository.RelativePath -> Evidence.PinnedDiff -> Either Evidence.EvidenceProblem Evidence.ValidatedPinnedDiff
pin = Evidence.validatePinnedDiff
pinnedView :: Evidence.ValidatedPinnedDiff -> Evidence.PinnedDiffView
pinnedView = Evidence.validatedPinnedDiff
ordinaryRouterRecord :: Declaration.RouterDeclarationView -> ()
ordinaryRouterRecord value = Generic.from value `seq` ()
ordinaryPinnedRecord :: Evidence.PinnedDiffView -> ()
ordinaryPinnedRecord value = Generic.from value `seq` ()
'''
CASES = [
    ('Principal.AgentPrincipal', 'parse'),
    ('Config.Port', 'parse'),
    ('Config.ByteLimit', 'parse'),
    ('Config.SecretText', 'render'),
    ('Reviewed.FullCommit', 'parse'),
    ('Overlay.CapabilityId', 'parse'),
    ('Overlay.CapabilityRevision', 'parse'),
    ('Overlay.ResolvedCapabilitySet', 'parse'),
    ('Inspection.InspectionCredential', 'render'),
    ('Repository.Revision', 'parse'),
    ('Repository.RelativePath', 'parse'),
    ('Router.ValidatedRouteDecision', 'parse'),
    ('Auth.BearerToken', 'render'),
    ('Position.ToolPosition', 'parse'),
    ('Assignment.AssignmentKey', 'parse'),
    ('Claim.ClaimOwner', 'parse'),
    ('Decision.DecisionFailure', 'parse'),
    ('Correlation.RunCorrelationId', 'parse'),
    ('Correlation.CallCorrelationId', 'parse'),
    ('Instructions.InstructionBundle', 'parse'),
    ('Declaration.ValidatedRouterDeclaration', 'generic'),
    ('Evidence.ValidatedPinnedDiff', 'generic'),
]

with tempfile.TemporaryDirectory(prefix='shikigami-opaque-types-') as directory:
    source = Path(directory) / 'OpaqueBoundary.hs'
    def compile(body):
        source.write_text(HEADER + body)
        return subprocess.run(['cabal', 'exec', '--', 'ghc', '-fno-code', '-package-id', CORE_UNIT, str(source)], cwd=ROOT, capture_output=True, text=True, timeout=45)
    result = compile(POSITIVE)
    assert result.returncode == 0, (result.stdout, result.stderr)
    print('opaque boundary: public factories/adapters: passed', flush=True)
    for kind, operation in CASES:
        if operation == 'parse':
            body = 'bypass :: Aeson.Value -> Parser ' + kind + '\nbypass = Aeson.genericParseJSON Aeson.defaultOptions\n'
        elif operation == 'render':
            body = 'bypass :: ' + kind + ' -> Aeson.Value\nbypass = Aeson.genericToJSON Aeson.defaultOptions\n'
        else:
            body = 'bypass :: ' + kind + ' -> ()\nbypass value = Generic.from value `seq` ()\n'
        result = compile(body)
        assert result.returncode != 0, (kind, 'generic bypass still compiles')
        assert all(fragment in result.stderr for fragment in ['Generic', kind.split('.')[-1]]), (kind, result.stderr)
        print('opaque boundary: ' + kind + ' generic ' + operation + ' refused: passed', flush=True)

    for kind, view in [('Declaration.ValidatedRouterDeclaration', 'Declaration.RouterDeclarationView'), ('Evidence.ValidatedPinnedDiff', 'Evidence.PinnedDiffView')]:
        result = compile('bypass :: ' + view + ' -> ' + kind + '\nbypass = ' + kind + '\n')
        assert result.returncode != 0, (kind, 'constructor is public')
        assert kind.split('.')[-1] in result.stderr and any(fragment in result.stderr.lower() for fragment in ['not in scope', 'does not export', 'illegal term-level use']), (kind, result.stderr)
        print('opaque boundary: ' + kind + ' constructor refused: passed', flush=True)
        result = compile('bypass :: ' + view + ' -> ' + kind + '\nbypass = coerce\n')
        assert result.returncode != 0, (kind, 'representation coercion is public')
        assert all(name.split('.')[-1] in result.stderr for name in [kind, view]), (kind, result.stderr)
        print('opaque boundary: ' + kind + ' coercion refused: passed', flush=True)
        result = compile('bypass :: Aeson.Value -> Parser ' + kind + '\nbypass = Aeson.parseJSON\n')
        assert result.returncode != 0, (kind, 'context-free JSON admission is public')
        assert all(fragment in result.stderr for fragment in ['FromJSON', kind.split('.')[-1]]), (kind, result.stderr)
        print('opaque boundary: ' + kind + ' unchecked JSON refused: passed', flush=True)
