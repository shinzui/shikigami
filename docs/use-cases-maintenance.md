# Maintaining use cases

[The use-case catalog](use-cases/index.md) describes user outcomes and the features needed
to deliver them. It uses the shared
[JTBD use-case profile](mori://shinzui/okf-profiles/profiles/use-cases), bootstrapped with
`okf profile init` against the authoritative upstream `v0.20.0` tag and its generated
Dhall integrity hash. The bundle declares OKF 0.2 and is registered in `mori.dhall` as
`use-cases`. Allocate handles with:

```sh
okf id next docs/use-cases UC --profile docs/use-cases/profile.dhall
```

Preserve `UC-N` handles across edits and use canonical cross-repository addresses such as:

```text
mori://shinzui/shikigami/okf/use-cases/concepts/UC-1
```

Each use case records actor/situation/motivation/outcome jobs, feature ownership, observable
acceptance, and request links. Mirror the union of feature-level `improvementRequests` at
the top level, and add body links to each request so the OKF graph is navigable. Link local
plans and capability evidence in the body; use intended canonical Mori URIs for external
artifacts even when discovery is stale. Themes live in `use-cases/themes/` and have both
frontmatter slugs and body links from the use cases that use them.

Separate current implementation from planned coverage. An unimplemented ExecPlan is not a
delivered feature; an existing plan may supply only part of a request. Reuse and update
existing IRs when their owned capability fits, create requests only for uncovered scope,
and identify conditional backends or optional deployment surfaces explicitly. A new
scenario does not imply acceptance, implementation, release, or live qualification.

Record truthful `generated` provenance. Preserve historical review entries and their exact
covered document revisions; add `reviews`/`verified` only for reviews that actually occur.
The validation recipes omit `--strict` because the profile recommends independent review
and new machine-authored records have not received it. To inspect those advisories, run
the corresponding `okf validate` command with `--strict`; do not invent reviews to silence
them.

After changes, update the affected bundle logs and run:

```sh
just use-cases-index
just improvement-requests-index
just use-cases-validate
just improvement-requests-validate
mori validate
okf graph docs/use-cases
```

Also inspect local Markdown links, job/feature name references, request unions, and the
reciprocal use-case links in owning IRs. Profile validation checks metadata and bundle
integrity; it does not prove runtime claims or every cross-bundle relationship. Keep
explanatory guidance outside generated `index.md` files.

Refresh local discovery after registration or handle changes:

```sh
mori register --local
mori path mori://shinzui/shikigami/okf/use-cases/concepts/UC-1
```

This upkeep does not require editing implementation plans or starting work on them. Any
later workflow implementation follows [workflow versioning](workflow-versioning.md).
