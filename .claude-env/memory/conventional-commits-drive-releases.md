---
name: conventional-commits-drive-releases
description: In variant-inc repos deployed through Octopus, the release version comes from CONVENTIONAL COMMIT prefixes — a commit without one produces no new package and the workflow still goes green
metadata:
  type: feedback
---

`variant-inc/iaac-risingwave-onprem` (and other repos using `variant-inc/actions-octopus`
via `octo.yaml`) derive the release version from **conventional commit prefixes**.

Verified 2026-09-01 by correlating main's history with the releases:

| Commit subject | Release |
|---|---|
| `fix: import existing SM secrets…` | 0.5.3 |
| `feat(terraform): initialize Terraform configuration…` | 0.5.2 |
| `feat(dev): add Entra ID OIDC connector…` | 0.5.1 |
| `INFRA-1674: add manifests/op-usxpress-prod (#32)` | **none** |
| `INFRA-1674: remove the five unconditional import blocks (#31)` | **none** |

Both unprefixed commits are mine. The workflow ran, reported **success**, and printed
"Create/Update Release complete" — but with no version bump it **updated the existing
0.5.3 release** rather than building a new package. Release `0.5.3` therefore still
selects package `0.5.1`, an August build, while every other release's package matches its
own version.

**Why it matters:** promoting that release would have deployed August's `deploy/`
directory — including the five `import` blocks we removed — and the prod plan would have
failed on exactly the thing the PR fixed. A green pipeline, a real release, and stale
content.

**How to apply:** in any repo whose `octo.yaml` pushes to Octopus, write commit subjects as
`fix: …`, `feat: …`, `feat(scope): …`. `INFRA-1234: …` is the house style for *notes*, not
for commits in these repos. After merging, confirm a release exists whose **package version
equals the release version** — that equality is the check, not the workflow's green tick.

Squash-merge uses the PR title, so the PR title is what must carry the prefix.

Related: [[octopus-green-but-no-apply]], [[adjacent-step-green-signals]],
[[risingwave-prod-terraform-via-octopus]].
