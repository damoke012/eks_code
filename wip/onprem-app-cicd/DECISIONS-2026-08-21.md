# Decisions on every open on-prem ticket — 2026-08-21

Taken by Dare Oke, who is admin on the AWS accounts, the clusters and the repos. Recorded
here because a decision that lives only in a Jira comment is a decision nobody can find.

The board had 15 open tickets, of which **five were described as blocked on another
person**. Four of those five were not blocked at all — they were waiting on a *preferred*
solution when an already-proven alternative was available. That is the theme of this
document.

Each entry: **the decision**, why, **what it costs**, and what it unblocks.

---

## 1. INFRA-1636 + INFRA-1650 — prod Argo CD Git credential and ApplicationSet

**Blocked on:** an org-owned GitHub App. `dare-x` is a member of `variant-inc`, not an
owner, so the New GitHub App page 404s. The request has sat unsent since 2026-08-20.

**DECISION: drop the GitHub App requirement. Use a repository deploy key, exactly as
shipped on QA in INFRA-1647.**

A deploy key is repo-owned, has no expiry, survives offboarding, and satisfies the
standing "no CI/CD tied to any one person" requirement just as well as an App does. It was
proven end to end on op-usxpress-qa on 2026-08-20. We are admin on the repositories, so we
can add one without asking anyone.

**What it costs — stated plainly.** A deploy key is **per repository**. One app, one key.
The App's real advantage is that a single installation covers every repo in the org and
issues short-lived tokens Argo CD renews itself. At two or three applications the deploy
key is fine; at fifteen it is an administrative mess. So this is the right decision *now*
and the wrong one *eventually*.

**Therefore:** the App is not abandoned, it is deferred, and it gets its own ticket rather
than silently blocking two others. When an owner is available it becomes a migration, not
a prerequisite.

**Unblocks:** INFRA-1636 and INFRA-1650 both move from "waiting on someone else" to
"ours, ready to implement". Neither is closeable until the prod credential is live and an
Application actually syncs — the QA lesson (INFRA-1648, then broken an hour later by
PR #100) is that a credential is proven by a sync, not by a secret existing.

---

## 2. INFRA-1656 — auto-merge means every PR is an immediate prod deploy

**DECISION: branch protection on `op-prod` requiring one approving review. Adopt option
(a). Leave `op-dev` and `op-qa` fast.**

We own the repository settings. The cost of a review gate on prod is one round trip per
prod change; the cost of not having it was PR #109 landing on production before op-dev had
proven anything, carrying a defect (`force: "true"` instead of `"enabled"`).

**Not adopting** option (d) — a check requiring the change to be live elsewhere first.
It is the more correct control and it is also a bespoke CI job nobody will maintain.
Review-required gets most of the benefit for none of the upkeep. If prod changes start
arriving unverified anyway, revisit.

**Closeable as soon as the setting is applied**, which is two `gh api` calls.

---

## 3. INFRA-1642 — Flux Git token at source, and alert on stale sources

**DECISION: split it. The alerting half is done — it became INFRA-1657 and INFRA-1659.
Re-scope this ticket to the token alone, and resolve the circularity by moving Flux's Git
credential off a PAT entirely.**

The circular problem was real: External Secrets Operator is itself reconciled by Flux, so
sourcing Flux's own Git credential from an `ExternalSecret` cannot work at bootstrap —
nothing has reconciled ESO yet when Flux first needs to read the repository.

The way out is not to solve the circularity but to remove the need for it. **A PAT needs
rotating because it expires and because it belongs to a person. An SSH deploy key does
neither.** Convert the `flux-system` and `infra` GitRepository sources from
`https://` + PAT to `ssh://` + deploy key — the same credential type already proven for
Argo CD on QA.

The credential then legitimately stays a **bootstrap secret**, written once by the cluster
stand-up (Terraform) and never rotated, which is not a workaround but the correct place
for it: bootstrap material belongs to the thing that bootstraps.

**What it costs.** A per-repository key again (see §1), and an `ssh://` URL change on all
three cluster branches — and `ssh://` and `https://` are not interchangeable to either
Flux or Argo CD, which is exactly what broke op-qa delivery for 18 hours in PR #100. This
change must be made on the branch and diffed in full before pushing.

---

## 4. INFRA-1639 — Argo CD SSO for application teams

**Blocked on:** an Entra app registration. Dare has no Azure access, so this cannot
proceed as scoped and has not moved since 2026-08-18.

**DECISION: do not use Entra. Use AWS IAM Identity Center as the OIDC/SAML provider,
through Argo CD's bundled Dex.**

We are admin in AWS. We already proved the identical model for cluster access on
op-usxpress-qa — `aws-iam-authenticator` on the control plane, access granted by assigning
an AWS SSO permission set, no per-person cluster change (INFRA-1638's direction). Using
the same identity source for Argo CD means one place to grant and revoke, and it works
today without waiting on anyone with Azure rights.

**What it costs.** Entra is the corporate directory of record and Identity Center is
downstream of it, so this is one hop further from the source of truth. In exchange it is
achievable. If Azure access arrives later, moving Dex from a SAML connector to an OIDC one
is a config change, not a redesign.

---

## 5. INFRA-1654 — `ghostunnel-rw-postgres` listens on 4567, not 5432

**Blocked on:** a message to Idris that has not been sent.

**DECISION: stop waiting. Raise the PR ourselves, and tell him it exists rather than
asking permission to write it.**

The port has been wrong for eleven weeks on dev and QA — `rw-postgres` has never been
reachable. The readiness probe passes because it checks the status port, which is up. It
is a one-line change in a manifest we can read and he can approve in the PR. Sending a
message and waiting for a reply to then write a one-line PR is two round trips where one
will do.

**Still tell him** — the `COMMS-TO-IDRIS-2026-08-20.md` draft also covers the Postgres
password change in his namespace and the meta-pod recreation that still needs his nod.
That message goes regardless; it just stops being a prerequisite.

---

## 6. INFRA-1655 — shared ECR registry has no write boundary

**DECISION: the on-prem half is answered and mitigated. The EKS half is cloud platform's,
and this ticket stays open under their name rather than ours.**

515 of 517 repositories in account 064859874041 grant org-wide push and there is no
registry-level policy. On-prem is safe from it because `require-image-digest` is Enforce on
all three clusters — a mutated tag cannot be pulled by digest. That mitigation is real and
it is in place.

EKS is not mitigated: `usxpress-prod` alone has 2763 tag references, 733 into the shared
registry, and no image admission control at all. That is not ours to fix and we should not
hold a ticket open pretending otherwise.

**What it costs.** Handing it over risks it rotting. Mitigated by assigning it explicitly
rather than leaving it unassigned, and by the finding being written down here.

---

## 7. INFRA-1638 — AWS SSO to op-usxpress-dev and op-usxpress-prod

**DECISION: proceed, dev first, prod in a scheduled window. We are admin in both accounts,
so the permission sets are ours to create.**

Not blocked, just not started. The op-qa implementation is proven and portable
(`wip/onprem-qa-access/aws-sso-webhook/`). Per cluster it needs: an AWS SSO permission set
in that account, the role ARN mapped in `aws-auth`, `enable_aws_iam_authenticator` set as
an **Octopus project variable** (git `.tfvars` are not read — the deploys inject
`TF_VAR_*`), `TfApply=true` scoped to the environment, and a Talos machineconfig patch
pointing the apiserver at the webhook.

**What it costs.** The machineconfig patch changes the API server on production. That is a
change window, not an afternoon. Dev has no such constraint and should go first — and dev
going first is also what makes prod verifiable, which is currently only possible via
break-glass.

**This is the ticket that unlocks the most**, because "we cannot see prod" has been the
qualifier on nearly every claim made in the last three days.

---

## 8–11. The ones where the decision is "not ours", stated so explicitly

| Ticket | Decision |
|---|---|
| **INFRA-1635** Deploy overlays, digest-pinned | Stays open, blocked on **INFRA-1644**. The QA overlay meets the written AC, but `PIPELINE_DIR` points at the smoke payload, so nothing real is promoted. Closing it on the letter of the AC would be exactly the 1640/1641 mistake. |
| **INFRA-1644** Reconcile `pipelines/Brand` against op-dev | **Tim's.** The repo defines sinks that the live dev cluster does not run. We cannot decide which is correct — that is a question about what the pipeline is *for*. Needs assigning to him. |
| **INFRA-1637** Rotate Confluent credentials | **Idris has it, In Progress.** Leave alone. Still the most security-urgent item on the board. |
| **INFRA-1651** Terraform path into ECR account 064859874041 | Ours, not started, no blocker. Real work: the repository and its policy were made by hand in INFRA-1633 and are outside Terraform. |

---

## 12. INFRA-1657 / 1658 / 1659 — the alerting tickets filed today

**DECISION: sequence them strictly. 1657 first, then 1658, then 1659 — and do not let
1659 jump the queue because it is the most visible.**

Turning on delivery before triaging the 54 outstanding alerts would deliver two months of
backlog on day one, including at least one likely false positive
(`KubeControllerManagerDown` on Talos) and application outages that are not ours
(`attrition/`, `io-curt/`, NotReady since 2026-06-24). The channel would be dismissed
within a week and the next real alert with it.

1657 is small and independent — a PodMonitor for `flux-system` on three branches — and
without it every Flux rule stays permanently inactive no matter how good delivery becomes.

---

## Outcome — applied 2026-08-21

All twelve decisions recorded on their tickets via
`scripts/decide-and-close-2026-08-21.py`.

- **INFRA-1656 CLOSED.** Branch protection applied to `op-prod`:
  `required_approving_review_count: 1`, `dismiss_stale_reviews: true`,
  `enforce_admins: false`. The script verified it against the GitHub API before closing —
  it would have refused on no protection, protection without a review block, or a review
  block requiring zero approvals.
- **INFRA-1660 filed** — migrate deploy keys to an org GitHub App, the deferred scaling work.
- **INFRA-1642 re-scoped** to *"Fix the Flux Git credential at source: move it off a PAT to
  a deploy key"*.
- **Ten tickets assigned** to Dare. Three deliberately left: 1637 (Idris, In Progress),
  1644 (Tim), 1655 (needs a named cloud-platform owner).

⚠️ **What the branch protection actually costs, now that it is live.** Auto-merge on
`op-prod` no longer completes without a review, which is the point. `enforce_admins: false`
means an admin can still merge deliberately — so for a one-person team this is a **speed
bump, not a wall**: it converts an accidental prod deploy into a conscious override. That
is what option (a) was chosen to do, and it is worth being clear it is not an enforcement
boundary against ourselves.

## What this changes on the board

| Was | Now |
|---|---|
| 1636, 1650 blocked on a GitHub App owner | ours, deploy-key pattern, ready to implement |
| 1639 blocked on Entra / Azure access | ours, AWS Identity Center via Dex |
| 1654 blocked on a message to Idris | ours, raise the PR |
| 1656 needs "whoever owns repo settings" | ours, branch protection on `op-prod` |
| 1642 half-finished and unclear | re-scoped to the token; alerting is 1657/1659 |
| 5 tickets "blocked on someone else" | **1** (INFRA-1637, correctly, with Idris) |

**Proven:** four of five "blocked on another person" tickets were blocked on a preference,
not a person; a deploy key satisfies every stated requirement the GitHub App was chosen
for, at the cost of per-repo scaling.
**Tested and killed:** "we must wait for an org owner" (QA already shipped without one);
"ESO must hold Flux's Git credential" (bootstrap material belongs to the bootstrapper).
**Traps:** `ssh://` and `https://` are not interchangeable and swapping them silently broke
op-qa for 18 hours — diff the branch in full; a deploy key does not scale past a handful of
repos, so the App ticket must actually be filed, not just intended.
