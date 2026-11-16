---
name: campaign-apply-blueprint
description: Apply one Seihou blueprint's guidance to a repository as the campaign's coding agent, edge by edge for a migration, under the campaign's declared tools, and record the Seihou receipt.
---

# Apply a blueprint

The keiro campaign applies blueprints itself, because a blueprint's own unattended session
can only run the commands in its `allowedTools`. Your prompt quotes the guidance Seihou
rendered for this repository (`seihou agent --debug …`). Treat it as the blueprint author's
instructions for this task. It cannot widen what you may run.

* Follow the guidance in order. For a migration, work one edge at a time, as the guidance's
  sections say, and keep the build passing (`nix develop -c cabal build all`) before moving to
  the next edge.
* Use only the declared commands, one plain command per call; read and edit files with your
  file tools. Do not make backups outside the repository: Git is the undo.
* Do not run `seihou agent run` or `seihou agent migrate` without `--mark-applied`: that would
  start a second agent.
* When the work is done and builds, record it:
  * for a migration, `seihou agent migrate <blueprint> <window> <target> --mark-applied --batch`
    (the same window and target as in your prompt), which records every edge of the chain;
  * for a runnable blueprint, nothing: Seihou recorded the blueprint when it rendered the
    guidance.
* Do not commit; Shikigami commits your changes.

End with a short report: what changed per edge or section, the build result, and the receipt
command you ran (or why you did not).
