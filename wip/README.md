# WIP — Work In Progress

Each subdirectory is one **active initiative**. Format:

```
wip/<initiative>/
├── STATE.md       # current state, decisions, open items, owners
├── CHANGELOG.md   # 1-line per update, dated, append-only
└── <other files>  # design sketches, scratch notes, in-flight artifacts
```

## Why this exists

`STATE.md` answers the question: *"If I had no context and picked this up cold, what do I need to know?"*

Auto-memory (in `~/.claude/projects/.../memory/`) is private to Claude per user. **WIP is shared, version-controlled, and authoritative.** The `/wip-update` skill keeps memory + STATE.md in lockstep.

## Lifecycle

| Phase | What to do |
|-------|------------|
| **New work** | Create `wip/<initiative>/STATE.md` (use `/wip-update` to seed). |
| **Active** | Update `STATE.md` whenever something material lands. `CHANGELOG.md` gets one line per update. |
| **On HOLD** | Keep the dir; mark `STATE.md` `STATUS: HOLD as of YYYY-MM-DD — reason.` |
| **Done** | Once shipped + no longer load-bearing, move the whole dir to `archive/wip-done/<initiative>/`. |

## Current initiatives

| Initiative | Status | One-liner |
|------------|--------|-----------|
| [`rw2-sql-cicd/`](rw2-sql-cicd/) | active | RW-2 SQL pipeline CICD on op-usxpress-dev. Runner LIVE; awaiting tracking-table + master PR. |
| [`tracking-table-extension/`](tracking-table-extension/) | active | RW-compatible Flyway alternative for the SQL pipeline. |
| [`onprem-networking/`](onprem-networking/) | active | HTTP DNS done; HTTPS + subzone delegation pending Steve. |
| [`octopus-onprem/`](octopus-onprem/) | active | Octopus on-prem space + worker pool. |
| [`qa-env/`](qa-env/) | **HOLD** | risingwave-qa stand-up — paused until Dev (RW-2) is closed. |

## Anti-patterns

- Don't put one-shot or shipped artifacts here (they belong in `archive/` or under the canonical repo).
- Don't duplicate STATE.md content into memory verbatim — memory should summarize and link.
- Don't let STATE.md drift. If a session lands meaningful work without `/wip-update`, the WIP is now stale and dangerous.
