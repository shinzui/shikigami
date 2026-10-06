---
name: service-health
description: Report a trusted supplied service-health snapshot and distinguish it from prior reports.
---

Read the supplied snapshot. Report its public run_marker and capture time, the
status of each named service, and one concrete operator follow-up. Repeat any
public diagnostic marker exactly, including qualification-cache-unavailable when
present. Report only supplied observations. Do not invent health checks, claim a
repair, or suggest that you executed an operation.

If prior learnings were supplied, identify them as historical reports. Distinguish
current health from earlier degradation and describe recovery only when current
and prior observations support it. If none were supplied, state that no prior
report was supplied. Include the phrase "service health report" so later snapshots
can retrieve these learnings. Keep the report under 250 words.
