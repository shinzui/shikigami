# 0106. The Keiro upgrade closes on a bounded macOS profile

Date: 2026-10-31

Status: accepted

## Context

MasterPlan 16 expanded the released-cohort migration into exhaustive current-guide
adoption. Four runtime/domain/inspection children were accepted, while individual
domain-value waves repeatedly ran complete macOS builds and serial PostgreSQL
suites. The user explicitly said macOS verification is enough and requested
completion after twelve hours. Further open-ended refactoring would prevent the
requested upgrade closure.

## Decision

Freeze the implemented Keiro 0.22 candidate and accept the tested arm64 macOS,
GHC 9.12.4, PostgreSQL 18/PGMQ profile. Stop Linux/Apple-container/remote-builder
qualification for this initiative. Existing Linux evidence stays historical;
macOS compilation or runtime tests do not certify Linux containment.

Treat the remaining exhaustive domain/identity/decoder review as standalone
plan108. This is the bounded finish interpretation communicated to the user,
not a claim that all 913 declarations satisfy the domain guide. Preserve every
open finding and the frozen source denominator. The domain-guide row becomes
explicitly deferred with its follow-up owner; it is never marked compliant or
not applicable because of cost. Only that named clause may be deferred by the
upgrade validator. New defects in the upgrade's exercised behavior remain gates.

Final acceptance combines the already passing full macOS build and behavioral/
compiler/native checks with remaining package/migration tests, real CLI and HTTP
contracts outside the checkout, exact source-closure export, inventory validation
and a first-deployment runbook. No large-suite repeat follows documentation-only
edits. Cold Nix rebuilding, Linux containment, live vendor credentials and a real
Kafka broker are outside the selected final profile and are not certified.

## Alternatives rejected

Continuing one scalar refactor and full-suite cycle at a time ignores the user's
completion request. Marking the complete domain audit compliant would falsify its
worklist. Dropping the source row or leaving ownership implicit hides remaining
work. Claiming unexecuted platforms or services from compilation would overstate
the accepted evidence.

## Consequences

The upgrade may close with a specific, machine-checked follow-up disposition.
Future domain work preserves actual authorization/accounting/recovery and follows
the then-current workflow deployment rules. The final release profile is explicit;
expanding it requires new evidence. Source/compiler/flags, schema ownership and
all implemented runtime invariants remain qualified on macOS.

## References

- [MasterPlan 16](../masterplans/16-upgrade-shikigami-to-keiro-0-22-and-retire-superseded-runtime-workarounds.md)
- [Plan108](../plans/108-complete-the-remaining-domain-scalar-identity-and-decoder-audit.md)
- [Rollout](../operations/keiro-0.22-rollout.md)
