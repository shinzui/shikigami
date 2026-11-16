---
name: campaign-reflect
description: Reflect on one repository's keiro modernization run and name what the campaign playbook should do differently in the next repository.
---

# Reflect on the campaign run

Read what this run did in this repository: the commits since the starting commit
(`git log`, `git show`), the MasterPlan and ExecPlans it wrote, the Seihou receipts in
`.seihou/manifest.json`, and the build results quoted in your prompt. Change no file.

Name learnings that would make the next repository's run cheaper or more correct. Examples:
a step that should run earlier, a probe that was missing, a prompt that misled an agent, or a
blueprint whose rule needs refining. Each learning is one or two sentences and names its
evidence. Suggest a change to the campaign playbook or its skills only when a learning needs
one.
