---
name: github-immutable-oidc-subject
description: MEASURED 2026-10-21 — newly created GitHub repos emit IMMUTABLE OIDC subjects embedding numeric org/repo IDs, so a trust policy copied from an older repo fails as "Not authorized to perform sts:AssumeRoleWithWebIdentity"
metadata:
  type: reference
---

A GitHub Actions OIDC subject is **not always** `repo:<org>/<name>:ref:refs/heads/<branch>`
any more. Repos with **immutable subject claims** emit numeric IDs instead:

    repo:usxpressinc@101195652/risingwave@1428674918:ref:refs/heads/master

Read it per repo — never assume:

    gh api /repos/<org>/<repo>/actions/oidc/customization/sub

| | `use_immutable_subject` | prefix |
|---|---|---|
| `usxpressinc/risingwave-poc` (older) | false | `repo:usxpressinc/risingwave-poc` |
| `usxpressinc/risingwave` (created 2026-10-21) | **true** | `repo:usxpressinc@101195652/risingwave@1428674918` |

**Why:** on 2026-10-21 a trust policy was extended with
`repo:usxpressinc/risingwave:ref:refs/heads/master`, read back correctly, and the build still
failed `Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity`.
The policy was right for a format that repo does not emit. **The error names IAM and sends
you to the role; the fault is in the claim.** Two repos, same org, same workflow, different
subject formats — because one is newer.

**How to apply:** when wiring a NEW repo to an existing OIDC role, read the sub customisation
of BOTH the working repo and the new one before writing the trust policy. Add the immutable
form; keep the plain form too, since it costs nothing and covers the setting being changed.
The numeric IDs are stable — they are what makes the claim immutable — so this does not rot.
Related: [[two-orgs-join-at-ecr-not-github]], [[gha-oidc-needs-environment-claim]],
[[v1-tag-is-moved-by-hand]].
