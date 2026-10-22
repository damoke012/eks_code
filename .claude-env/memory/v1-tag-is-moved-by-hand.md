---
name: v1-tag-is-moved-by-hand
description: MEASURED 2026-10-21 — variant-inc/iaac-onprem-app-cicd has NO release automation; `v1` is a hand-moved tag, so merging to main ships nothing to consumers
metadata:
  type: reference
---

`variant-inc/iaac-onprem-app-cicd` publishes `app-build-push.yml`, which every on-prem app
build consumes as `…/app-build-push.yml@v1`. Measured 2026-10-21:

| | |
|---|---|
| tags | **`v1` only** |
| `v1` points at | `0d68e2c`, a **docs** commit dated 2026-10-21 |
| release automation | **none** — the repo has one workflow file and it is the reusable workflow itself |

**So merging a PR to `main` changes nothing for any consumer.** The `v1` tag has to be
force-moved by hand:

    git checkout main && git pull --ff-only
    git tag -f v1 && git push -f origin v1

**Why it matters:** on 2026-10-21 Renovate opened a **security** PR bumping
`aquasecurity/trivy-action` 0.28.0 → 0.35.0 against a real supply-chain compromise
(CVE-2026-33634). Merging it alone would leave every consumer still calling the compromised
version through `@v1` — a green PR that delivers nothing. Exactly the shape of
[[adjacent-step-green-signals]] and [[conventional-commits-drive-releases]], but with no
automation at all rather than a missing prefix.

**How to apply:** after merging anything to that repo, **move the tag and read it back**
(`git log -1 --format='%h %s' v1`). And moving `v1` changes the build for every consumer at
once with no staging — so check who consumes it first
(`gh search code 'iaac-onprem-app-cicd' --owner variant-inc --owner usxpressinc`). As of
2026-10-21 the pricing app's build workflow did not exist yet, which made that the cheapest
moment to re-pin third-party actions by **commit SHA** rather than tag — the fix Wiz's three
Low findings were asking for, and the right lesson after a tag-push compromise.

Sibling repo `variant-inc/iaac-risingwave-cicd@v1` serves the RisingWave SQL builds and is
likely the same pattern — verify before assuming its merges ship either.
