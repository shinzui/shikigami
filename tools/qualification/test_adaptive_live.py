import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('live_driver', HERE / 'adaptive-delivery.py')
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
legacy_spec = importlib.util.spec_from_file_location('legacy_controls', HERE / 'test_adaptive_delivery.py')
legacy = importlib.util.module_from_spec(legacy_spec)
legacy_spec.loader.exec_module(legacy)


class LiveAdmissionTests(unittest.TestCase):
    @staticmethod
    def configuration(directory):
        application = {
            'authorization': {'actions': {'mode': 'kikan', 'caller_id': 'approved-trial',
                'kikan_en': {'base_url': 'https://kikan.example.invalid'},
                'shomei': {'base_url': 'https://shomei.example.invalid', 'client_id': 'qualification'},
                'en': {'issuer_public_keys': '1:' + '0' * 64, 'schema_hashes': 'sha256:test'}}},
            'credentials': {'authorization': {'actions': {'shomei': {'client_secret': 'PRIVATE_MARKER'}}},
                            'providers': {'openai': {'api_key': 'PRIVATE_MARKER'}}},
            'behavior': {'provider': 'openai', 'model': 'gpt-4o-mini', 'decisionModels': [
                {'alias': role, 'version': '1', 'bindingId': 'reviewed-' + role, 'bindingVersion': '1',
                 'provider': 'openai', 'model': 'gpt-4o-mini', 'thinking': 'default',
                 'max_tokens': 1024, 'timeout_ms': 30000} for role in driver.live.ROLES]}}
        private = directory / 'application.json'
        private.write_text(json.dumps(application))
        private.chmod(0o600)
        limits = {dimension: {'tag': 'Limited', 'contents': amount} for dimension, amount in
                  [('ActiveWork', 8), ('LifetimeDescendants', 32), ('ModelAttempts', 48),
                   ('ToolAttempts', 128), ('Tokens', 2000000)]}
        limits['CostMicroUsd'] = {'tag': 'ExplicitlyUnbounded'}
        value = json.loads((driver.FIXTURE / 'fixture.yaml').read_text()) | {
            'mode': 'live', 'runtime': '/nix/store/' + 'a' * 32 + '-explicit-runtime',
            'live': {'application_config': str(private), 'durationSeconds': 900, 'limits': limits}}
        return value, application

    def test_private_configuration_rejects_symlinks_links_fifos_and_public_files(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            value, _ = self.configuration(directory)
            path = Path(value['live']['application_config'])
            driver.live.validate(value['live'], 48, 1800)
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                driver.live.private_json(path)
            path.chmod(0o600)
            linked = directory / 'hard-link'
            os.link(path, linked)
            with self.assertRaises(ValueError):
                driver.live.private_json(path)
            linked.unlink()
            linked.symlink_to(path)
            with self.assertRaises(OSError):
                driver.live.private_json(linked)
            fifo = directory / 'fifo'
            os.mkfifo(fifo, 0o600)
            with self.assertRaises(ValueError):
                driver.live.private_json(fifo)

    def test_missing_authority_credentials_and_unenforceable_limits_refuse_before_runtime(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            value, application = self.configuration(directory)
            mutations = [lambda a: a['authorization']['actions'].update(mode='disabled'),
                         lambda a: a['authorization']['actions']['kikan_en'].update(base_url='http://localhost'),
                         lambda a: a['authorization']['actions'].update(caller_id='workspace-fixture'),
                         lambda a: a['credentials']['providers']['openai'].update(api_key=''),
                         lambda a: a['behavior'].update(provider='stub'),
                         lambda a: a['behavior']['decisionModels'][0].update(provider='stub'),
                         lambda a: a['behavior']['decisionModels'][0].update(timeout_ms=0),
                         lambda a: a.update(database={'connection_string': 'production'})]
            for mutate in mutations:
                altered = copy.deepcopy(application)
                mutate(altered)
                Path(value['live']['application_config']).write_text(json.dumps(altered))
                with self.assertRaises(ValueError):
                    driver.live.validate(value['live'], 48, 1800)
            Path(value['live']['application_config']).write_text(json.dumps(application))
            for dimension in ['Tokens', 'ModelAttempts', 'ToolAttempts']:
                altered = copy.deepcopy(value['live'])
                altered['limits'][dimension] = {'tag': 'ExplicitlyUnbounded'}
                with self.assertRaises(ValueError):
                    driver.live.validate(altered, 48, 1800)
            config = directory / 'invalid.json'
            config.write_text(json.dumps(value | {'live': {}}))
            config.chmod(0o600)
            result = subprocess.run([sys.executable, str(HERE / 'adaptive-delivery.py'), '--mode', 'live',
                '--config', str(config), '--artifact-dir', str(directory / 'evidence')], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            manifest = next((directory / 'evidence').glob('*/manifest.json')).read_text()
            self.assertEqual(json.loads(manifest)['cases'], [])
            self.assertNotIn('PRIVATE_MARKER', manifest + result.stdout + result.stderr)

    def test_live_dispatch_uses_only_selected_mode_and_removes_staged_secrets(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            value, _ = self.configuration(directory)
            config = directory / 'live.json'
            config.write_text(json.dumps(value))
            config.chmod(0o600)
            value = driver.load_config(config, 'live')
            evidence = directory / 'evidence'
            evidence.mkdir()
            with patch.object(driver.shutil, 'which', return_value='available'), \
                    patch.object(driver, 'run_case', return_value={'state': 'passed'}) as run, \
                    patch.object(driver, 'native_evidence', return_value={'format': 3}) as verify:
                manifest = driver.qualify(evidence, value, 'live')
            self.assertEqual(manifest['state'], 'passed')
            self.assertIn('--adaptive-live-only', run.call_args.args[2])
            self.assertEqual(verify.call_args.kwargs['live_settings'], value['live'])
            self.assertFalse((evidence / 'live-private/application.json').exists())
            self.assertNotIn('PRIVATE_MARKER', json.dumps(manifest))

    def live_evidence(self, directory):
        config, application = self.configuration(directory)
        value, recovery, roles, _ = legacy.AdaptiveDeliveryTests().live_worker_records()
        selected = recovery['worker_selections']
        decision = copy.deepcopy(selected[0])
        decision['assignmentId'] = 'adaptive-assignment'
        decision['selection']['descriptor']['alias'] = 'adaptive'
        decision['selection']['permittedAliases'] = ['adaptive']
        selected.append(decision)
        value['providerCalls']['adaptive'] = 1
        descriptors = []
        transports = []
        for record in selected:
            descriptor = record['selection']['descriptor']
            role = descriptor['alias']
            descriptor.update(provider='openai', api='chat-completions', modelId='gpt-4o-mini', bindingId='reviewed-' + role)
            descriptors.append(copy.deepcopy(descriptor))
            for call in record['calls']:
                if role == 'adaptive':
                    call.update(attemptId='adaptive-attempt', operationId='adaptive-operation')
                    call['receipt']['assignmentId'] = record['assignmentId']
                    call['receipt']['request'].update(attemptId=call['attemptId'], operationId=call['operationId'])
                outcome = call['outcome']
                outcome.update(reportedModel='gpt-4o-mini', providerCallId=call['attemptId'])
                facts = outcome['compliance']
                facts.update(providerCallId=call['attemptId'], requestedAlias=role, observedModelId={'observed': 'gpt-4o-mini'},
                             requestedModelId='gpt-4o-mini', resolvedModelId='gpt-4o-mini')
                facts['endpoint'].update(provider='openai', api='openai-chat-completions')
                if role == 'adaptive':
                    call['decision'] = {'receipt': copy.deepcopy(call['receipt']), 'model': copy.deepcopy(descriptor),
                                        'terminal': 'CallSucceeded', 'callId': 'decision-call', 'facts': copy.deepcopy(facts)}
                    outcome['compliance'] = None
                transports.append({'tuple': {key: descriptor[key] for key in ['provider', 'api', 'endpointClass', 'modelId', 'thinking']},
                                   'evidenceRequest': {'run_id': 'root-run', 'attempt': 1}, 'providerCallId': facts['providerCallId'], 'maxTokens': 1024, 'timeoutMs': 30000})
        total = sum(value['providerCalls'].values())
        envelope = {'limits': [[d, config['live']['limits'][d]] for d in driver.live.DIMENSIONS], 'cutoff': '2026-11-09T00:15:00Z'}
        value.update(format=3, liveTransportCalls=total, sessionMessageResultCounts=[4, 5, 5], root={
            'envelope': envelope, 'active': 0, 'unknown': 0, 'cancelled': False, 'overage': False,
            'usage': {'held': [], 'settled': [['ModelAttempts', total], ['Tokens', total * 31], ['CostMicroUsd', total * 2]]}})
        recovery.update(format=3, transportCalls=transports, admission={
            'rootId': value['rootId'], 'admittedAt': '2026-11-09T00:00:00Z', 'envelope': envelope, 'descriptors': descriptors,
            'authority': {'kikanBaseUrl': application['authorization']['actions']['kikan_en']['base_url'],
                          'shomeiBaseUrl': application['authorization']['actions']['shomei']['base_url'], 'callerId': 'approved-trial'}},
            messages=[{'sequence': sequence} for sequence in [0, 0, 0, 0, 1]],
            authority=[{'principal': 'coordinator', 'resource': 'owned-resource', 'schemaHash': 'sha256:test',
                        'requestId': 'unique-proof-request', 'checkedAt': 'opaque-consistency-token', 'expiresAt': '2026-11-09 00:01:00 UTC'}],
            terminal_replay={'sameEvidence': True, 'providerCallsBefore': 'a' * 64, 'providerCallsAfter': 'a' * 64})
        return value, recovery, config

    def test_live_call_checks_actual_thinking_wire_billing_and_enforced_reservation(self):
        value, recovery, roles, admitted = legacy.AdaptiveDeliveryTests().live_worker_records()
        record = recovery['worker_selections'][0]
        role = record['selection']['descriptor']['alias']
        admitted[role]['thinking'] = 'ThinkingHigh'
        record['selection']['descriptor']['thinking'] = 'ThinkingHigh'
        for call in record['calls']:
            call['outcome']['compliance']['thinking']['requested'] = 'high'
            call['outcome']['compliance']['strength'] = 'fully_observed'
        driver.validate_worker_selections(value, recovery, roles, admitted=admitted)
        for mutate in [lambda c: c['outcome']['compliance'].update(observedModelId='unobserved'),
                       lambda c: c['outcome']['compliance']['costMicroUsd'].update(numerator=3),
                       lambda c: c['receipt']['request'].update(policy='AdmittedUnknownUsage'),
                       lambda c: c['receipt']['request']['quantities'].__setitem__(2, ['Tokens', 1])]:
            changed = copy.deepcopy(recovery)
            mutate(changed['worker_selections'][0]['calls'][0])
            with self.assertRaises(ValueError):
                driver.validate_worker_selections(value, changed, roles, admitted=admitted)

    def test_failed_live_trial_retains_owner_holds_and_partial_bundles_without_secrets(self):
        with tempfile.TemporaryDirectory() as raw, tempfile.TemporaryDirectory(
                prefix='shikigami-workspace-run.', dir='/tmp') as native:
            directory, source = Path(raw), Path(native) / 'evidence'
            config, _ = self.configuration(directory)
            source.mkdir()
            (source / 'adaptive-live-roots.json').write_text('[{"rootId":"held-root","state":{"unknown":1}}]')
            (source / 'adaptive-live-dispatches.jsonl').write_text('{"tuple":{"provider":"openai"}}\n')
            (source / 'application.json').write_text('PRIVATE_MARKER')
            (source / 'adaptive-provider-calls').symlink_to(source / 'application.json')
            archives = source / 'adaptive-artifacts'
            archives.mkdir()
            (archives / 'workspace-0.bundle').write_bytes(b'partial forensic bytes')
            attempt = directory / 'attempt'
            attempt.mkdir()
            def run(_directory, name, *args, **kwargs):
                if name == 'native':
                    (attempt / 'native.log').write_text('Private fixture evidence: ' + native + '\n')
                    return {'state': 'failed', 'exit_code': 1}
                return {'state': 'passed'}
            with patch.object(driver.shutil, 'which', return_value='available'), patch.object(driver, 'run_case', side_effect=run):
                result = driver.qualify(attempt, config, 'live')
            self.assertEqual(result['state'], 'failed')
            retained = result['failed_live_evidence']['retained']
            self.assertIn('adaptive-live-roots.json', retained)
            self.assertIn('git-artifacts/workspace-0.bundle', retained)
            self.assertNotIn('adaptive-provider-calls', retained)
            self.assertNotIn('application.json', retained)
            self.assertFalse((attempt / 'live-private/application.json').exists())

    def test_live_returned_artifacts_use_the_same_exact_pair_checks(self):
        for stale in [False, True]:
            with self.subTest(stale=stale), tempfile.TemporaryDirectory() as raw, tempfile.TemporaryDirectory(
                    prefix='shikigami-workspace-run.', dir='/tmp') as native:
                directory = Path(raw)
                live_value, recovery, config = self.live_evidence(directory)
                starts, value, artifact, _ = legacy.AdaptiveDeliveryTests().native_artifacts(directory, Path(native), stale_consumer=stale)
                value.update(live_value)
                artifact.write_text(json.dumps(value))
                (Path(native) / 'evidence/adaptive-recovery.json').write_text(json.dumps(recovery))
                if stale:
                    with self.assertRaisesRegex(ValueError, 'journey'):
                        driver.native_evidence(directory, starts, live_settings=config['live'])
                else:
                    verified = driver.native_evidence(directory, starts, live_settings=config['live'])
                    self.assertEqual(verified['returned_artifact_verification']['worker_pairs_recomputed'], 2)
                    self.assertEqual(verified['returned_artifact_verification']['artifacts'], 6)

    def test_live_root_accepts_the_retained_native_resource_wire_format(self):
        value = json.loads((driver.ROOT / 'docs/evidence/adaptive-delivery/native-facts.json').read_text())
        root = value['native']['root']
        envelope = copy.deepcopy(root['envelope'])
        spent = driver.resource_map(root['usage']['settled'])
        envelope['limits'] = [[dimension, {'tag': 'ExplicitlyUnbounded'} if dimension == 'CostMicroUsd'
                               else {'tag': 'Limited', 'contents': max(1, spent.get(dimension, 0) + 1)}]
                              for dimension in driver.live.DIMENSIONS]
        root['envelope'] = envelope
        cutoff = driver.datetime.fromisoformat(envelope['cutoff'].replace('Z', '+00:00'))
        from datetime import timedelta
        driver.validate_live_root(root, envelope, admitted_at=cutoff - timedelta(seconds=900))
        with self.assertRaises(ValueError):
            driver.resource_map([['Tokens', 1], ['Tokens', 2]])
        with self.assertRaises(ValueError):
            driver.resource_map({'Tokens': 1})

    def test_live_verifier_accounts_for_coordinator_and_workers_together(self):
        with tempfile.TemporaryDirectory() as raw:
            value, recovery, config = self.live_evidence(Path(raw))
            driver.validate_live_evidence(value, recovery, config['live'])
            mutations = [lambda r: r['admission']['authority'].update(callerId='workspace-fixture'),
                         lambda r: r['admission']['descriptors'][0].update(modelId='other-model'),
                         lambda r: r['transportCalls'][0].update(providerCallId='other-call'),
                         lambda r: r['worker_selections'][-1]['calls'][0]['decision'].update(receipt={}),
                         lambda r: r.update(authority=[]),
                         lambda r: r.update(format=1),
                         lambda r: r['terminal_replay'].update(providerCallsAfter='b' * 64)]
            for mutate in mutations:
                changed = copy.deepcopy(recovery)
                mutate(changed)
                with self.assertRaises(ValueError):
                    driver.validate_live_evidence(value, changed, config['live'])
            for mutate in [lambda v: v['root'].update(unknown=1),
                           lambda v: v['root']['usage']['settled'].__setitem__(1, ['Tokens', 0]),
                           lambda v: v.update(liveTransportCalls=999),
                           lambda v: v['providerCalls'].update(adaptive=0)]:
                changed = copy.deepcopy(value)
                mutate(changed)
                with self.assertRaises(ValueError):
                    driver.validate_live_evidence(changed, recovery, config['live'])


def native_preflight_controls(executable=None):
    if executable is None:
        executable = subprocess.run(['cabal', 'list-bin', 'workspace-linux-fixture'], check=True,
                                    capture_output=True, text=True, timeout=30).stdout.strip()
    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        config, application = LiveAdmissionTests.configuration(directory)
        driver.live.stage_value(config, directory / 'staged')
        app_path = directory / 'staged/application.json'
        limits_path = directory / 'staged/limits.json'
        good_limits = json.loads(limits_path.read_text())
        cases = [('configured HTTP', None, None, True),
                 ('stub behavior', lambda a: a['behavior'].update(provider='stub'), None, False),
                 ('disabled authority', lambda a: a['authorization']['actions'].update(mode='disabled'), None, False),
                 ('unbounded tokens', None, lambda l: l['limits'].__setitem__(4, ['Tokens', {'tag': 'ExplicitlyUnbounded'}]), False),
                 ('finite invoice ceiling', None, lambda l: l['limits'].__setitem__(5, ['CostMicroUsd', {'tag': 'Limited', 'contents': 1}]), False),
                 ('missing role', lambda a: a['behavior']['decisionModels'].pop(), None, False),
                 ('missing key', lambda a: a['credentials']['providers']['openai'].pop('api_key'), None, False),
                 ('missing timeout', lambda a: a['behavior']['decisionModels'][0].pop('timeout_ms'), None, False)]
        for name, change_app, change_limits, accepted in cases:
            app, limits = copy.deepcopy(application), copy.deepcopy(good_limits)
            if change_app:
                change_app(app)
            if change_limits:
                change_limits(limits)
            app_path.write_text(json.dumps(app))
            limits_path.write_text(json.dumps(limits))
            environment = os.environ.copy()
            environment['OPENAI_API_KEY'] = 'PRIVATE_MARKER'
            environment['SHIKIGAMI_BEHAVIOR_PROVIDER'] = 'stub'
            result = subprocess.run([executable, 'adaptive-live-preflight', str(app_path), str(limits_path)],
                                    capture_output=True, text=True, timeout=20, env=environment)
            assert (result.returncode == 0) == accepted, (name, result.returncode, result.stderr)
            assert 'PRIVATE_MARKER' not in result.stdout + result.stderr, name
        print(f'PASS {len(cases)} native live preflight controls; no model dispatch')


if __name__ == '__main__':
    if sys.argv[1:] == ['--native-preflight']:
        native_preflight_controls()
    elif len(sys.argv) == 4 and sys.argv[1:3] == ['--native-preflight', '--executable']:
        native_preflight_controls(sys.argv[3])
    else:
        unittest.main()
