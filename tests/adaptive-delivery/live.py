#!/usr/bin/env python3
"""Private live admission and guest staging. Never discover ambient credentials."""
import argparse
import json
import os
from pathlib import Path
import stat
from urllib.parse import urlsplit

ROLES = ['adaptive', 'producer', 'producer-review', 'consumer', 'consumer-review']
DIMENSIONS = ['ActiveWork', 'LifetimeDescendants', 'ModelAttempts', 'ToolAttempts', 'Tokens', 'CostMicroUsd']


def private_json(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid()
                or info.st_mode & 0o077 or info.st_size > 65536):
            raise ValueError('live configuration must be a private owned regular file of at most 64 KiB')
        content = os.read(fd, 65537)
        if len(content) > 65536:
            raise ValueError('live configuration grew beyond its bound')
        return json.loads(content)
    finally:
        os.close(fd)


def https(value):
    if not isinstance(value, str):
        return False
    url = urlsplit(value)
    return (url.scheme == 'https' and bool(url.hostname) and not url.username and not url.password
            and not url.query and not url.fragment and not any(c.isspace() for c in value))


def validate(value, attempts, timeout):
    if not isinstance(value, dict) or set(value) != {'application_config', 'durationSeconds', 'limits'}:
        raise ValueError('live configuration requires an explicit private application file, duration and limits')
    duration = value['durationSeconds']
    if type(duration) is not int or not 1 <= duration <= 1200 or duration + 60 > timeout:
        raise ValueError('live duration must fit both the native and host deadlines')
    limits = value['limits']
    if not isinstance(limits, dict) or set(limits) != set(DIMENSIONS):
        raise ValueError('live root must declare every resource dimension')
    for name in DIMENSIONS:
        bound = limits[name]
        if name == 'CostMicroUsd':
            if bound != {'tag': 'ExplicitlyUnbounded'}:
                raise ValueError('HTTP invoice ceilings are unsupported')
        elif (not isinstance(bound, dict) or set(bound) != {'tag', 'contents'} or bound['tag'] != 'Limited'
              or type(bound['contents']) is not int or not 0 < bound['contents'] <= 9223372036854775807):
            raise ValueError('live enforceable limits must be finite positive int64 values')
    if limits['ModelAttempts']['contents'] != attempts:
        raise ValueError('live root and driver model-attempt ceilings differ')
    config = private_json(value['application_config'])
    if not isinstance(config, dict) or set(config) != {'authorization', 'credentials', 'behavior'}:
        raise ValueError('live application input may supply only authorization, credentials and behavior')
    try:
        actions = config['authorization']['actions']
        if (actions['mode'] != 'kikan' or not https(actions['kikan_en']['base_url'])
                or not https(actions['shomei']['base_url']) or actions['caller_id'] == 'workspace-fixture'
                or not actions['caller_id'] or not actions['shomei']['client_id']
                or not actions['en']['issuer_public_keys'] or not actions['en']['schema_hashes']
                or not config['credentials']['authorization']['actions']['shomei']['client_secret']):
            raise ValueError('live production authority is incomplete')
        behavior = config['behavior']
        if behavior['provider'] not in ['anthropic', 'openai', 'openai-responses'] or not behavior['model']:
            raise ValueError('live behavior must explicitly select an HTTP provider and model')
        if 'base_url' in behavior and not https(behavior['base_url']):
            raise ValueError('live behavior endpoint must use HTTPS')
        bindings = behavior['decisionModels']
        if (not isinstance(bindings, list) or len(bindings) != len(ROLES)
                or {b['alias'] for b in bindings} != set(ROLES)):
            raise ValueError('live catalog must contain exactly the five roles')
        for binding in bindings:
            vendor = binding['provider']
            credential_vendor = 'anthropic' if vendor == 'anthropic' else 'openai'
            if (vendor not in ['anthropic', 'openai', 'openai-responses'] or not binding['model']
                    or binding['bindingId'].startswith('adaptive-fixture-')
                    or not config['credentials']['providers'][credential_vendor]['api_key']
                    or type(binding['max_tokens']) is not int or binding['max_tokens'] <= 0
                    or type(binding['timeout_ms']) is not int or not 0 < binding['timeout_ms'] <= duration * 1000
                    or ('base_url' in binding and not https(binding['base_url']))):
                raise ValueError('live binding lacks credentials or bounded HTTP options')
    except (KeyError, TypeError, AttributeError):
        raise ValueError('live production configuration is incomplete') from None
    return config


def stage_value(value, target):
    """Snapshot admitted secrets into the guest, excluding host database/config."""
    live = value['live']
    application = validate(live, value['max_model_attempts'], value['timeout_seconds'])
    directory = Path(target)
    directory.mkdir(mode=0o700)
    for name, content in [('application.json', application), ('limits.json', {
            'durationSeconds': live['durationSeconds'],
            'limits': [[dimension, live['limits'][dimension]] for dimension in DIMENSIONS]})]:
        fd = os.open(directory / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as output:
            json.dump(content, output)


def stage(source, target):
    stage_value(private_json(source), target)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--stage', type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        stage(args.config, args.stage)
    except (OSError, ValueError, KeyError, TypeError):
        parser.exit(2, 'REFUSED: invalid private live configuration; no model work\n')
