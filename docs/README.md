# Shikigami documentation

Current implementation and planning boundary checked 2026-10-29 against the
working tree (audit started at `ac971c3`). The current branch also contains uncommitted plan
refinements; design text is not implementation evidence.

| Reader task | Start here |
| --- | --- |
| Declare, run or call an agent | [User guide](user/README.md), [HTTP API](user/http-api.md), [CLI](user/cli.md) |
| Find implemented consumer provisions | [Capability catalog](capabilities/index.md), [public-surface census](capabilities-coverage.md) |
| Understand packages and durable owners | [Package map](architecture/packages.md), [domain inventory](architecture/shikigami-domain-inventory.md) |
| Configure and operate a deployment | [Configuration](operations/configuration.md), [operator commands](operations/operator-cli.md), [action authorization](operations/action-authorization.md) |
| Recover Skill operations or inspect resource use | [Durable execution](operations/durable-execution.md), [resource accounting](operations/execution-resources.md), [Baikai execution](operations/baikai-execution.md) |
| Change durable code safely | [Workflow versioning](workflow-versioning.md), [typed-decision authoring](shikumi-flow-decisions.md) |
| Choose the next delivery lane | [Roadmap](roadmap.md), [MasterPlans](masterplans/), [ExecPlans](plans/) |
| Inspect adaptive delivery requirements | [Use case](use-cases/adaptive-autonomous-delivery.md), [theme](use-cases/themes/autonomous-work.md) |
| Use the visual guides | [Onboarding](artifacts/shikigami-engineer-onboarding.html), [roadmap](artifacts/roadmap.html), [adaptive delivery](artifacts/adaptive-autonomous-objectives.html) |

Root accounting, assignment selection and recoverable Skill operations are
implemented. Continuing-worker command/session primitives are partial; real
workspace and objective/checkpoint providers remain gates. Repository catalog
admission performs no filesystem I/O. Objective persistence, API/CLI and durable
capabilities remain planned in MasterPlan 17. Full adaptive and recurring delivery
is not yet qualified. See the roadmap for each owning plan.

The configured dependency baseline remains Keiro 0.18. The
[dependency cohort](dependency-cohort.md) records that baseline; MasterPlan 16 and
[the 0.22 audit](architecture/keiro-0.22-pattern-audit.md) describe the planned
upgrade. The 0.17/0.18 adoption and rollout documents preserve their dated
qualification evidence. [Implementation order](architecture/implementation-order.md)
and [initial spec](initial-spec.md) retain historical design context; they do not
override current guides, contracts or workflow safety rules.

The capability, use-case and user-guide catalogs are OKF bundles. Maintain them
through [capability upkeep](capabilities-maintenance.md),
[use-case upkeep](use-cases-maintenance.md) and the user-guide maintenance notes.
Regenerate indexes and validate the edited bundles. Historical bundle log entries
and plan acceptance records describe their original checkpoints. This documentation
refresh does not rerun runtime acceptance or re-probe live dependencies.
