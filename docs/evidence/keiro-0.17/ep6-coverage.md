# EP-6 corpus reconciliation

The final inventory contains 116 rows and no open applicability or pending-owner
disposition. Entry-point, navigation, example, legacy-upgrade, and governance
documents are explicitly contextual, superseded, or not applicable. Applicable
rows point to their executed owner and child evidence.

The final corpus revisions match the planning snapshot:

| Corpus | Revision | State |
|---|---|---|
| `mori://shinzui/keiro-runtime-patterns` | `c0d7f5cc4246689d15344b9f45b6e763e1cde886` | clean |
| `mori://shinzui/haskell-jitsurei` | `fb6574d971da2bc3ae52bce279828577895ca5f6` | normative files unchanged; unrelated untracked `mori/checklist.dhall` |
| `mori://shinzui/postgresql-jitsurei` | `76a646c2f265dfe84451b32626c4436b74f56314` | clean |

The final qualification command results are recorded separately in
`qualification.md` after the public Hackage solve and clean-checkout gate.
