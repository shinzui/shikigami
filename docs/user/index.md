---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Explanation

- [Memory & Sessions](memory.md) - Understand how agents recall and record memory across runs and sessions.

# Guide

- [Finite adaptive delivery](adaptive-delivery.md) - Run one objective through the compiled adaptive-delivery Flow with a finite resource root and cutoff.
- [Give an agent your command-line tools](declared-tools.md) - Declare the CLI tools and MCP server tools an agent may call, grant the declaration once, bind MCP servers and bound CLI tools in the operator tools file, and read every call in the action record.
- [Detectors — the intelligence layer as declared agents](detectors.md) - Check detector execution support and configure supported agents.
- [Flows](flows.md) - Implement durable Flow behaviors in a flow pack, compose them into an executable, and inspect them.
- [HTTP API — agents and runs](http-api.md) - Authenticate, discover declared agents, request an idempotent run, and follow its lifecycle through the typed client or HTTP.
- [Run agents on your own machine](local-operator.md) - Run a declared agent against your own repository under the local-operator trust tier, confirm its grant once, and read the action record.
- [Link objectives to external trackers](objective-trackers.md) - Bind an existing Rei intention, review external proposals, and recover uncertain publication without duplicate actions.
- [Durable objectives](objectives.md) - Create and continue an objective across runs and conversations, then explicitly accept its integrated result.
- [Where a run's result goes](outputs.md) - Declare a run's outputs, rely on the composition's default (a local report under the local operator), require an approval before delivery, and resolve it from the local inbox.
- [Playbooks](playbooks.md) - Declare a multi-step, multi-repository procedure in Dhall, check it, and run it durably with coding agents, declared tools and approvals.
- [Routine agents](routine-agents.md) - Create a routine agent with one command, run it in a repository with one confirmation, schedule it on your machine, and see and fix its runs.
- [Skills — authoring a SKILL.md behavior](skills.md) - Author and validate a skill directory for a Shikigami Skill behavior.
- [Typed decisions in Flows](typed-decisions.md) - Configure model aliases, run the typed decision example, and preserve governed results and attempt evidence on replay.
- [Unrequested work](unrequested-work.md) - What a person sees when an agent proposes work nobody asked for, and what answering does.
- [Active-work watchdog notices](watchdog.md) - Understand quiet-work and drift notices and inspect their bounded evidence before acting.
- [Writing Agents](writing-agents.md) - Declare agent identity, behavior, triggers, outputs, tools, memory policy, and routing in Dhall.

# Navigation

- [Shikigami — User Guide](README.md) - Find the right guide for declaring, running, and operating Shikigami agents.

# Reference

- [Behaviors — what an agent does](behaviors.md) - Choose between ShikumiProgram, Skill, CoordinatingSkill, CodingAgent, Playbook and Flow.
- [CLI Reference](cli.md) - Look up Shikigami commands, options, and database recipes.
- [Kikan service outputs and sink grants](sinks.md) - Look up Kikan output declarations, delivery behavior, and permission requirements.
- [Triggers — when an agent fires](triggers.md) - Look up manual, schedule, stream, and addressed-event triggers and their feedback guards.

# Runbook

- [Architecture-practice reviews](architecture-practice-reviews.md) - Trigger and resolve practice reviews, configure attention, and recover delivery.

# Tutorial

- [Getting Started](getting-started.md) - Try a stock declaration without services, then run a local agent with a migrated database.
- [The Living Loop — running agents end to end](living-loop.md) - Exercise the worker, stream feedback loop, addressed conversations, and delegation.
