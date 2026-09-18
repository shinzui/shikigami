# Keiro 0.17 release-cohort evidence

Captured on 2026-09-18 from authoritative Hackage package metadata and upstream release tags. Mori was used first to resolve the local sources for `mori://shinzui/keiro`, `mori://shinzui/kioku`, `mori://shinzui/pgmq-hs`, and `mori://shinzui/shibuya-pgmq-adapter`.

## Published releases

Hackage lists `0.17.0.0` as a normal release for each of the seven Keiro packages. All seven upstream tags peel to commit `11e0bba4f634ac6fa4526e2814bd5a8177e3f050`. The published `keiro-pgmq-0.17.0.0` package requires the `pgmq-*` packages and `pgmq-config` in the `>=0.6 && <0.7` range and `shibuya-pgmq-adapter ^>=0.16.0.0`.

Hackage lists PGMQ `0.6.1.0` and adapter `0.16.0.0`. Their upstream tags peel to `163413b3ccc85ce6a517646da6ff8969c2dd7482` and `7472c77690d833b76ba3ba36500ff2810c9f0fc8`, respectively.

## Blocking Kioku bound

Hackage's `kioku-core` version catalog contains no release newer than `0.6.0.0`. The published `kioku-core-0.6.0.0` package requires both `keiro >=0.16.0.0 && <0.17` and `keiro-core >=0.16.0.0 && <0.17`. Its upstream `v0.6.0.0` tag peels to `1fb4fa39747f03ff5be6c5f07ae3a1d385cdfbee`.

An isolated Cabal solve outside this repository reproduced the incompatibility without Shikigami's existing pins:

```bash
mkdir -p /tmp/shikigami-keiro-017-solve
cd /tmp/shikigami-keiro-017-solve
cabal install --dry-run --lib keiro-0.17.0.0 kioku-core-0.6.0.0 \
  --package-env /tmp/shikigami-keiro-017-solve/env
```

The solver reported:

```text
rejecting: kioku-core-0.6.0.0
  (conflict: keiro==0.17.0.0, kioku-core => keiro^>=0.16.0.0)
skipping: kioku-core; 0.5.2.0 ... 0.1.0.0
  (has the same characteristics ... excludes 'keiro' version 0.17.0.0)
```

## Disposition

EP-1 remains in progress until compatible Kioku API, core, and migrations packages are published and an all-released solve succeeds. Shikigami does not add `allow-newer`, a source checkout, or widened local package bounds to bypass this release boundary. The required upstream work is a Kioku release whose Keiro and Keiro Core bounds admit `0.17.0.0`, with the three Kioku packages released as a coherent cohort. If that release also requires the Kioku 0.6 AI API migration, EP-1 must first expand its implementation and validation steps for the affected Shikigami call sites.

