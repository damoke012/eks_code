---
name: route-every-prompt-through-skills
description: Doke requires every prompt to be routed through the skills catalog — load what fits before acting, not only when a task looks ceremonial
metadata:
  type: feedback
---

Check the skill router on **every** prompt and load what fits. Proceed unaided only when
nothing matches.

**Why:** stated directly on 2026-08-20 — "You must use matt skills for all prompt its setup".
The kit is installed and the router is injected every turn; skipping it wastes work that is
already built. On that day's session only two skills ran (`wizard`, `capture-learning`)
across several hours, and three clear misses cost real time: six trial-and-error round trips
on a failing Job where `diagnosing-bugs` would have forced "what else does this overlay
assert that the server never agreed to?" after the first failure; eight `git archive`
workarounds instead of `resolving-merge-conflicts` on a tree unmergeable since Tuesday;
follow-up tickets hand-written into a script instead of `to-tickets`.

**How to apply:** the failure is never at the start of a task, it is mid-flow. Reaching for
a skill feels natural for ceremonial work (a walkthrough, a write-up) and unnatural when
deep in something technical — which is exactly when the structure pays. Treat "I am nearly
done, this one is quick" as the trigger to load the skill. Now rule 8 in CLAUDE.md.
