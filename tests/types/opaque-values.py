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
import Data.ByteString (ByteString)
import Data.Text (Text)
import Shikigami.Agent.Principal qualified as Principal
import Shikigami.App.Config qualified as Config
import Shikigami.Attestation.Reviewed qualified as Reviewed
import Shikigami.Capability.Overlay qualified as Overlay
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
        body = ('bypass :: Aeson.Value -> Parser ' + kind + '\nbypass = Aeson.genericParseJSON Aeson.defaultOptions\n') if operation == 'parse' else ('bypass :: ' + kind + ' -> Aeson.Value\nbypass = Aeson.genericToJSON Aeson.defaultOptions\n')
        result = compile(body)
        assert result.returncode != 0, (kind, 'generic bypass still compiles')
        assert all(fragment in result.stderr for fragment in ['Generic', kind.split('.')[-1]]), (kind, result.stderr)
        print('opaque boundary: ' + kind + ' generic ' + operation + ' refused: passed', flush=True)
