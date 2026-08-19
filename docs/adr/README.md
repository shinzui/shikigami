# Architecture Decision Records

Durable project memory: decisions that stay relevant after the plan that made
them is finished. An ExecPlan is active execution memory and is allowed to go
stale; these are not.

One decision per file, named `NNNN-kebab-slug.md`, numbered sequentially and
never renumbered. A record's number is stable across renames. Plain Markdown —
this corpus is not an OKF bundle and `mori.dhall` declares no bundle for it, so
do not add OKF frontmatter or a `docId` unless the repository adopts a profile
deliberately.

Each record states the context that forced a decision, the decision itself, the
alternatives rejected and why, and the consequences a future contributor will
actually feel. Supersede a record with a new one rather than editing its decision
in place; correcting an error or adding evidence is fine.

Cite a record from elsewhere in this repository by relative path. Cite a record
in another repository by its canonical Mori handle, never by a bare `ADR-N` or a
path into someone else's checkout.
