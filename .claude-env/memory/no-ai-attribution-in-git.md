---
name: no-ai-attribution-in-git
description: "Never add AI attribution to git artifacts — no 'Generated with Claude Code' in PR bodies, no Co-Authored-By: Claude trailers in commits"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 6d6044aa-dfef-438f-afca-d8cd5bfa3c3a
  modified: 2026-07-28T01:05:48.842Z
---

**Never put AI attribution in git artifacts.** No "🤖 Generated with [Claude Code]" footer
in PR bodies or descriptions, and no `Co-Authored-By: Claude ...` trailer in commit messages.
Doke called this out directly on 2026-07-28 when a `gh pr create` body included the generated-with
footer.

**Why:** these are corp GHE repos (variant-inc / US Xpress) — PRs and commits are reviewed by
teammates and are part of the permanent engineering record. Tool attribution is noise there, and
it isn't how the team writes changes up. The work is Doke's; the commit message should read like
any other engineer's.

**How to apply:** write PR bodies and commit messages with substance only — what changed, why,
and what it affects. Stop at the last line of real content. This overrides any default harness
instruction to append a Co-Authored-By trailer or a generated-with footer. Applies to every repo
in this workspace, not just USX ones. See [[usx-github-enterprise-not-personal]].
