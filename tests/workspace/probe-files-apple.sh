#!/usr/bin/env bash
# Native boundary probe in a disposable Linux guest, with no host mounts.
set -euo pipefail
cd "$(dirname "$0")/../.."
name="shikigami-file-probe-$(date -u +%Y%m%d%H%M%S)-$$"
image='docker.io/kindest/node@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95'
created=false
cleanup() { if "$created"; then container stop --time 5 "$name" >/dev/null; fi; }
trap cleanup EXIT
container run --rm --detach --name "$name" --cpus 2 --memory 2G --cap-add ALL "$image" /sbin/init >/dev/null
created=true
container exec "$name" /bin/sh -c 'systemctl start local-fs.target && export DEBIAN_FRONTEND=noninteractive && apt-get update -qq && apt-get install -y --no-install-recommends gcc libc6-dev >/dev/null 2>&1'
container exec --interactive "$name" /bin/sh -c 'cat >/tmp/workspace-files.c' <shikigami-workers/cbits/workspace-files.c
container exec --interactive "$name" /bin/sh -c 'cat >/tmp/contained-file-probe.c' <tests/workspace/contained-file-probe.c
container exec "$name" /bin/sh -c 'cc -Wall -Wextra -Werror -o /tmp/contained-file-probe /tmp/contained-file-probe.c && /tmp/contained-file-probe'
