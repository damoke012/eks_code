---
name: to-issues
description: Alias for the merged `to-tickets` skill. Use when the user types /to-issues, or asks to turn a plan, spec, design or the current conversation into issues/tickets in the project's issue tracker.
disable-model-invocation: true
---

# /to-issues → `to-tickets`

Upstream merged `to-plan` and `to-issues` into a single **`to-tickets`** skill and deleted `to-issues`
(mattpocock/skills PR #464, commit `386d4ff`). The old name is kept here so `/to-issues` never fails.

**Do this now:** invoke the **`to-tickets`** skill and follow it exactly. It cuts tracer-bullet vertical
slices with explicit blocking edges, and writes them to whichever tracker
`/setup-matt-pocock-skills` configured. This file holds no procedure of its own.
