---
name: capture-learning
description: Capture what was just learned into the knowledge base — use right after an investigation concludes, a bug is root-caused, an incident is resolved, a PR review lands, or whenever the user says "capture this", "write this up", "add this to the notes", "we figured it out", or "document what we found". Also use when a belief turned out to be wrong, or a procedure changed.
---

# Capture the learning before moving on

An investigation that is not written down has to be paid for twice. Run this the moment
something is figured out — not at the end of the session, when the detail has gone.

## The four questions

Answer all four. The third and fourth are the ones that get skipped, and they are the ones
that compound.

1. **What is now proven?** State it with its scope and a date. `etcd snapshots are stale` is
   not a finding; `op-usxpress-qa etcd snapshots stopped 2026-07-19, ExternalSecret green but
   value empty` is.
2. **What did we believe that was wrong?** Correct the old note *in place* — strike it and
   explain why, rather than deleting it. The wrong belief is why the next person will make
   the same mistake.
3. **Did a procedure change?** If yes, update the *skill*, not just the note. A note nobody
   opens changes nothing. This is the step that turns a finding into a behaviour.
4. **Could a check have caught it?** If yes, write the check. A finding that recurs was never
   really captured. Prefer a test that goes red over a paragraph that asks someone to remember.

## Where it goes

| Kind of thing | Destination |
|---|---|
| Facts about this environment | `wip/<workstream>/` — a dated note |
| A procedure that will repeat | `.claude/skills/<name>/SKILL.md` |
| Cross-session context | the memory directory (see `scripts/claude-env-backup.sh`) |
| A check | `scripts/`, or a hook in `.claude/hooks/` |

## House style

End every note with three sections: what was **proven**, what was **tested and killed**, and
the **traps**. Numbers carry a scope and a timestamp. Never delete a wrong claim — correct it
in place, so the reasoning that produced it stays visible.

## Before you finish

Run `bash scripts/kb-lint.sh`. It catches notes that have rotted — undated claims, references
to files that no longer exist, TODOs that outlived their ticket.
