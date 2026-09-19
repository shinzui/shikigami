# Keiro 0.17 release-cohort evidence

Captured on 2026-09-18 from authoritative Hackage package metadata and upstream release tags. Mori was used first to resolve the local sources for `mori://shinzui/keiro`, `mori://shinzui/kioku`, `mori://shinzui/pgmq-hs`, and `mori://shinzui/shibuya-pgmq-adapter`.

## Published releases

Hackage lists `0.17.0.0` as a normal release for each of the seven Keiro packages. All seven upstream tags peel to commit `11e0bba4f634ac6fa4526e2814bd5a8177e3f050`. The published `keiro-pgmq-0.17.0.0` package requires the `pgmq-*` packages and `pgmq-config` in the `>=0.6 && <0.7` range and `shibuya-pgmq-adapter ^>=0.16.0.0`.

Hackage lists PGMQ `0.6.1.0` and adapter `0.16.0.0`. Their upstream tags peel to `163413b3ccc85ce6a517646da6ff8969c2dd7482` and `7472c77690d833b76ba3ba36500ff2810c9f0fc8`, respectively.

## Kioku 0.7 publication

The earlier published `kioku-core-0.6.0.0` package required both `keiro >=0.16.0.0 && <0.17` and `keiro-core >=0.16.0.0 && <0.17`. Its upstream `v0.6.0.0` tag peels to `1fb4fa39747f03ff5be6c5f07ae3a1d385cdfbee`, which explains the initial solver failure captured below.

The owner reported publishing Kioku 0.7 on 2026-09-18. Mori-resolved source at
clean commit `37c3acd2d16e18c49217bc6189ea20b496907e3b` contains coherent
`kioku-api`, `kioku-core`, and `kioku-migrations` 0.7.0.0 Cabal files whose bounds
admit Keiro 0.17. The 0.7 migration payloads are byte-identical to 0.5.2. Local
package-path qualification builds all Shikigami packages and passes the Language 6,
worker and real old-to-new migration gates.

After `cabal update`, the public secure index remained at
`2026-09-18T23:13:22Z`; `cabal info kioku-core` still ended at 0.6.0.0 and the
0.7.0.0 package page returned HTTP 404. The upstream checkout also had no release
tag pointing at the commit. These observations can reflect Hackage propagation or
unfinished release finalization, but they cannot yet serve as consumer release
evidence.

A second `cabal update` at 2026-09-19T00:27Z returned the same index-state.
An exact `cabal info kioku-api-0.7.0.0 kioku-core-0.7.0.0
kioku-migrations-0.7.0.0` lookup stopped at the first package with `There is no
available version of kioku-api that satisfies ==0.7.0.0`.

At 2026-09-19T01:06:24Z the public secure index advanced and exposed
`kioku-api`, `kioku-core`, and `kioku-migrations` 0.7.0.0. Exact `cabal info`
queries confirmed that the published Core package requires Keiro and Keiro Core
`>=0.17.0.0 && <0.18`, and the published migrations package requires Keiro
Migrations in the same range. A detached Shikigami worktree with no
`cabal.project.local` downloaded and built all three packages from Hackage.

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

EP-1 is complete. The public Hackage index exposes all three Kioku 0.7 packages,
and the all-released solve, build, and aggregate gates pass without
`cabal.project.local`. Shikigami loads Kioku's host-owned AI runtime, resolves
`QueryEmbedding`, and falls back to keyword recall when the feature is disabled.
No `allow-newer` or widened package bound is used.
