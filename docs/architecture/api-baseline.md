# The API baseline

Shikigami has surfaces that things outside this repository's control depend on: a declaration
someone wrote, a script that calls a command, a flow pack in another repository, a client of
the HTTP API, a journal a run must resume from. This document says what those surfaces are,
how much each may be relied on, and what a change to one requires.

It is the policy behind `just api-baseline`. The plan that builds it is
[plan 136](../plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md).


## What a public surface is

A public surface is anything a consumer can come to depend on without reading Shikigami's
source. A module that only Shikigami's own packages import is not one. Each surface has one
entry in the inventory, `api-baseline/surfaces.dhall`, whose type is
`api-baseline/Surface.dhall`. An entry names:

- its **owner**, the plan that ships the surface and decides its changes;
- its **stability** level, below;
- its **rule**, one sentence stating what a compatible change is;
- its **check**, which compares the surface with a pinned copy;
- its **freeze**, which of the two baselines pins it (`Declaration` or `Kernel`);
- its **enforcement**: `Report` prints a finding, `Enforce` also fails the run.

An owning plan adds its entry in report mode in the commit that ships the surface. A freeze
sets the stability and turns enforcement on.


## The checks

| Check | What it pins | Breaking | Changed |
| --- | --- | --- | --- |
| `DhallSchema` | A schema's semantic hash and a corpus of real declarations | A corpus file no longer loads, or the schema no longer evaluates | The hash moved and the corpus still loads |
| `JournalCodec` | The JSON each corpus declaration is journaled as | A pinned encoding no longer decodes, or decodes to a different declaration | The declaration now encodes to different bytes |
| `OpenApi` | The HTTP API description | A removed path, operation, response status, response property or response enumeration value; a changed property type; a request property that became required | Any other difference |
| `CliHelp` | The `--help` text of listed verbs of an executable | An option or subcommand is no longer offered | Any other difference in the text |
| `ExportList` | The exported names of modules, read from GHC interface files | A name, constructor or field is no longer exported | A name is newly exported |
| `KeiroGate` | The durable workflow contract, through `just keiro-gate` | Any breaking finding of the gate | None |

A *breaking* finding does not obey the surface's rule. A *changed* finding differs from the
pin and obeys the rule: an additive change. Both are deliberate decisions, so both fail an
enforcing surface until it is re-pinned.


## The three stability levels

**Stable.** A consumer may build on it. A breaking change needs a new ADR, a compatibility
path and a re-pin in the same commit. The compatibility path depends on the surface: a
default for a new Dhall field, a `patch` for a workflow body, a codec that still reads the
old bytes, a deprecated route kept for one release. An additive change needs only the re-pin.

**Provisional.** The surface exists and is checked, and its shape may still move. A breaking
change needs a Decision Log entry in the owning plan and a re-pin. The surface's corpus is
updated in the same commit, so the next reader sees what changed.

**Internal.** No check and no promise. A flow pack may not import an internal module; the
kernel fitness check (`just kernel-fitness`) enforces that through the SDK components.

Every surface is provisional and report-only until its freeze. The declaration baseline
freezes what an operator writes and runs: the agent declaration, its journal encoding, the
playbook and operator files, and the local-work commands. The kernel baseline freezes the
rest: the pack SDK, the kernel ports, the durable wire, the HTTP API and the admin command.


## Running it

Build what the checks read, then run them from the repository root:

```sh
cabal build api-baseline shikigami shikigami-agent-run shikigami-core
just api-baseline
```

```text
api-baseline: 8 surfaces, 8 report-only, 0 enforcing
  agent-declaration        provisional  clean
  agent-journal-codec      provisional  clean
  cli-shikigami-agent-run  provisional  clean
  http-api                 provisional  clean
  durable-wire             provisional  clean
  cli-shikigami            provisional  clean
  flow-sdk                 provisional  clean
  pack-sdk                 provisional  clean
```

Each line ends in `clean`, `CHANGED` or `BREAKING`. A finding is printed below the table with
the rule it is held to and the path for a deliberate change:

```text
agent-declaration (provisional): BREAKING
  api-baseline/corpus/agents/repo-inventory.dhall no longer loads:
    Error: Expression doesn't match annotation
    { - delegationLimit : …
    , + delegationBudget : …
  Rule: Every declaration in the corpus keeps loading to the same value; a new field has a default.
  This surface is provisional. A breaking change needs a Decision Log entry in its owning
  plan and an updated corpus in the same commit, then: just api-baseline-pin agent-declaration
  Policy: docs/architecture/api-baseline.md
```

The exit status is 0 when every finding belongs to a report-only surface, 1 when an enforcing
surface has a finding, and 2 when a check could not run, for example because an executable
is not built. A check that cannot run is never reported as clean.

| Command | What it does |
| --- | --- |
| `just api-baseline` | Check every surface. |
| `just api-baseline --only <name>` | Check one surface; repeatable. |
| `just api-baseline --enforce` | Treat every surface as enforcing, to see what a freeze would refuse. |
| `just api-baseline-pin <name>` | Rewrite one surface's pinned files from the working tree. |
| `cabal run -v0 api-baseline -- list api-baseline/surfaces.dhall --freeze declaration` | Name the surfaces of one freeze. |
| `cabal run -v0 api-baseline -- exposure` | Measure how much of `shikigami-core` is exposed and how much a consumer imports. |


## Making a deliberate change

1. Make the change and run `just api-baseline`. Read the finding: it says whether the change
   is breaking for that surface.
2. Do what the surface's level requires: an ADR and a compatibility path for a stable
   surface, a Decision Log entry and an updated corpus for a provisional one.
3. Run `just api-baseline-pin <name>` and review its diff. A pin made by mistake hides a
   real break, so the diff of a pin is reviewed like code.
4. Commit the change, the record and the pin together.

A pin rewrites only the frozen files of one surface: goldens under `api-baseline/goldens/`,
the frozen API description under `api-baseline/frozen/`, or a schema's hash in the
inventory. It never changes an entry's stability or rule. The durable wire has no pin file;
its `since` commit is set in the inventory at the freeze.


## Where things are

| Path | What it holds |
| --- | --- |
| `api-baseline/Surface.dhall` | The type of an inventory entry. |
| `api-baseline/surfaces.dhall` | The inventory. |
| `api-baseline/corpus/` | Real declarations each schema must keep loading. |
| `api-baseline/goldens/` | Pinned journal encodings, help texts and export lists. |
| `api-baseline/frozen/` | The frozen HTTP API description. |
| `tools/api-baseline/` | The tool. Each check is a pure comparison with a thin IO wrapper, tested on synthetic input by `cabal test api-baseline-test`. |
