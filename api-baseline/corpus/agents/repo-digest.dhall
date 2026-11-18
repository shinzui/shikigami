-- A routine coding agent as `shikigami-local new repo-digest --coder` writes it
-- (EP-9, docs/user/routine-agents.md), with the outputs left to the composition
-- default (a local report under local-operator).
let R = ../../../schema/Routine.dhall

in  R.coder
      "repo-digest"
      "Summarize what changed in this repository in the last week, from git log, in five bullets."
