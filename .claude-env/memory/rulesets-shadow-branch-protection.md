---
name: rulesets-shadow-branch-protection
description: "When a GitHub repository ruleset governs a branch, the classic branch-protection API returns 404 — which reads as 'unprotected' — and `gh pr merge --admin` does NOT bypass a ruleset's CODEOWNERS requirement"
metadata:
  type: project
---

**Measured 2026-10-16 to 2026-10-19** across `variant-inc` repos while chasing why merges
needed someone else.

1. **`gh api repos/<o>/<r>/branches/<b>/protection` returns `404 Branch not protected`** on a
   branch that is, in fact, governed — by a **repository ruleset**, which is a different API:
   `repos/<o>/<r>/rulesets` and `rules/branches/<b>`. The 404 is the most misleading possible
   answer: it looks like a finding about the branch rather than about which API you asked.
2. **`gh pr merge --admin` does not bypass a ruleset.** It bypasses classic protection. A
   ruleset's **required-reviewer / CODEOWNERS** rule still refuses, so a repo that looks
   admin-mergeable is not, and the error arrives at merge time after the work is done.

**How to apply.** Before concluding a branch is unprotected, or that you can merge your own
PR, ask the **rulesets** endpoint too:

```
gh api "repos/<o>/<r>/rules/branches/<branch>" --jq '.[].type'
```

Empty output means ungoverned; a 404 from the *protection* endpoint means nothing at all.
Then line up the approver in advance — on `variant-inc` that has meant Parul
(she approved `actions-collection#99`; `iac-tf-manual-runs#39` was still waiting on
2026-10-20), and **Idris is not a code owner anywhere in the org**, so he cannot be the
reviewer however convenient that would be.

Related: [[a-guard-can-measure-the-wrong-thing]] (print the measurement beside the
threshold), [[octopus-deploy-can-gate-the-pr]] (the other gate that sits *before* merge).
