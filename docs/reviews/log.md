# Bundle Update Log

## 2026-08-27

* **Addition**: REV-1 requests changes to the ExecPlan 46 closeout: the plan's gates reproduce
  (801 tests, additive `keiro-gate`), but its Outcomes claim conformance coverage the spec does not
  contain, and master plan 9, the workflow-versioning inventory, and ADR 0034's trailing whitespace
  were left stale.
* **Addition**: REV-2 requests changes to `Shikigami.PracticeReview.Attention`: a replay after a
  journaled skip commits a reservation with no outbox message, and the semantic key hashes a
  model-chosen claim id.
* **Addition**: REV-3 approves the practice-review attention migration as additive, delivery-state
  free, and twice-applied.
* **Addition**: REV-4 requests changes to `Shikigami.PracticeReview.Authorization`: no path checks
  that a verified resolver is entitled to resolve the review, and the opaque credential type
  derives `Show`.
* **Addition**: REV-5 comments on `Shikigami.Flow.OpenTelemetryPracticeReview`: crash-shaped input
  failures, `show`-rendered problem claims, and a producer-trusted prior review id.
* **Addition**: REV-6 approves `Shikigami.PracticeReview.Capability` with notes on the leftover
  non-atomic attention interpreter and unbounded evaluator output.
* **Addition**: REV-7 requests changes to the architecture-practice reviews user guide: the
  resolution path has no production ingress and profile provisioning has no procedure.
* **Addition**: REV-8 requests changes to the improvement-requests corpus: repin from okf-profiles
  v0.10.0 to v0.13.1, move IR-4 out of `proposed`, and refresh the stale Mori registry entry.

## 2026-08-26

* **Bootstrap**: adopt the shared `assurance.reviews` profile from
  `mori://shinzui/okf-profiles/profiles/reviews`, declare this directory as an OKF v0.2
  bundle, and add strict profile and log validation.
