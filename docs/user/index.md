---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Explanation

- [Memory & Sessions](memory.md) - Understand how agents recall and record memory across runs and sessions.

# Guide

- [Detectors — the intelligence layer as declared agents](detectors.md) - Create detector agents using the shipped catalog and suppression rules.
- [Flows](flows.md) - Implement, register, and inspect durable lifecycle-backed Flow behaviors.
- [Skills — authoring a SKILL.md behavior](skills.md) - Author and validate a skill directory for a Shikigami Skill behavior.
- [Writing Agents](writing-agents.md) - Declare agent identity, behavior, triggers, sinks, memory policy, and routing in Dhall.

# Navigation

- [Shikigami — User Guide](README.md) - Find the right guide for declaring, running, and operating Shikigami agents.

# Reference

- [Behaviors — what an agent does](behaviors.md) - Compare deterministic, ShikumiProgram, Skill, and Flow behavior declarations.
- [CLI Reference](cli.md) - Look up Shikigami commands, options, and database recipes.
- [Sinks — what an agent produces](sinks.md) - Look up sink declarations, delivery behavior, and permission requirements.
- [Triggers — when an agent fires](triggers.md) - Look up schedule, stream, and addressed-event triggers and their feedback guards.

# Runbook

- [Architecture-practice reviews](architecture-practice-reviews.md) - Trigger and resolve practice reviews, configure attention, and recover delivery.

# Tutorial

- [Getting Started](getting-started.md) - Build Shikigami, validate a first agent, and run it with memory.
- [The Living Loop — running agents end to end](living-loop.md) - Exercise the worker, stream feedback loop, addressed conversations, and delegation.

