# Idris's board — review and next steps, 2026-08-25

Read from Jira, not from notes. 28 issues assigned to `ifagbemi@usxpress.com`
(`712020:d5331c18-…`); 14 open. Dispositions below are recommendations — the ones that say
CLOSE are safe to close on the evidence cited; the ones that say VERIFY are not.

---

## The two you asked about

### INFRA-1488 — app-managed secrets pattern + RW/postgres user creation → **SPLIT, then close half**

You were right, with a caveat. The ticket bundles two things:

* **"a documented, repeatable way to declare and consume secrets"** — **delivered, as a
  platform capability, not by Idris.** External Secrets Operator + the `ClusterSecretStore`
  + per-environment Secrets Manager paths, with the ownership line written down in
  `ONBOARDING.md`: *platform owns secret **delivery**, the app team owns secret **values***.
  That is exactly what the ticket asked for, and it now applies to every app, not just RW.
* **"RW / postgres user creation via the SQL pipeline"** — **not done**, and under the
  delivery standard it is no longer a "pattern" question at all. It is an Argo CD sync-hook
  Job in the app's own `deploy/`.

So: close the secrets half citing the platform capability, and let the user-creation half
live inside the containerisation work rather than as a standing pattern ticket. It should
not be on Idris as written — the part that was his has been overtaken.

Last touched **2026-07-10**.

### INFRA-1591 — Platform SSO via Entra → **CLOSE**

Both halves are done, and the half that was the point is done by the platform.

* **The reusable pattern** — that was the ticket's actual goal ("rather than wire this
  one-off for RisingWave, build a reusable platform SSO pattern"). Delivered 2026-08-25 as
  Entra OIDC on Argo CD across all three clusters, with no Dex at all. It generalises better
  than the RW approach because it needs no per-app Dex deployment.
* **RisingWave as first consumer** — Idris delivered that: Dex embedded in the RW console,
  QA dashboard SSO wired 2026-08-13, one Entra app (`e112d6ce-…`) shared dev + QA.

**One thing to hand him rather than assume.** This tenant does **not** emit a `groups` claim
to the confidential web flow — proven today across every configuration. If the RW console's
Dex config keys authorisation on group membership, it is either not doing group-based authz
at all, or it is relying on something that will not survive scrutiny. Worth him checking
before it matters. Route around it the same way we did: an **app role** and the `roles`
claim. See `.claude/skills/entra-authz-claims/SKILL.md`.

---

## Everything else open

| Key | Status | Age | Disposition |
|---|---|---|---|
| **INFRA-1626** obtain access to Talos config | TO DO | 18 Aug | **CLOSE — the blocker is gone.** `talosconfig` is in Secrets Manager at `op-usxpress-prod/talosconfig`, and `scripts/onprem-prod-kubeconfig.sh` rebuilds a working kubeconfig from it. Proven today: 13 prod nodes. |
| **INFRA-1489** sign off the RW-2 SQL CICD approach | TO DO | 28 May | **CLOSE — the design is superseded.** It gates `feat/onprem-rw2-adaptation` + `ONPREM_CICD.md`, the in-cluster ARC-runner design. The standard is now build → ECR by digest → Argo CD. Signing off a retired design is waste. Close against the INFRA-1644 decision. |
| **INFRA-1490** configure GitHub Environment `pipeline-approval` | TO DO | 28 May | **CLOSE with 1489.** The human gate under the standard is a PR plus a manual Argo sync on prod, not a GitHub Environment on `pipeline.yaml`. |
| **INFRA-1637** SECURITY: rotate Confluent credentials | In Progress | 18 Aug | **VERIFY AND CLOSE — most urgent open item.** He posted "Implementation Complete" on 18 Aug, but the AC has two halves: no plaintext in any catalog table **on any cluster**, and the old key **revoked**, not merely replaced. His comment names the live key. Confirm both. |
| **INFRA-1501** adopt hand-deployed `pg-postgresql` into source | In Progress | 10 Jun | **KEEP — more urgent than it reads.** This is the postgres RisingWave actually depends on, running outside GitOps. It is the same instance behind the QA password drift (INFRA-1652): initdb 11 Aug, secret rotated 12 Aug, the database never learned it, nine days silent. Un-GitOps'd critical state is how that happens. |
| **INFRA-1500** remove the unused `postgres` HelmRelease | In Progress | 29 May | **KEEP, small.** Verify it is still there first — 12 weeks is long enough for it to have gone. |
| **INFRA-1477** app-level SQL pipelines in **dev** | In Progress | 15 Jun | **RE-SCOPE.** Overlaps the delivery standard directly. Blocked on the INFRA-1644 decision about the dev ARC-runner pipeline's future; the repo and the live cluster have already diverged (`400-sink.rw` defines sinks dev does not run). |
| **INFRA-1475** provision RisingWave in **production** | TO DO | 22 May | **PARK.** Two blockers, neither his: prod has no ApplicationSet and no Git credential (INFRA-1650), and *whether RisingWave goes to prod at all* is still an open decision. |
| **INFRA-1534** Grafana "No Data" on op-dev | In Progress | 10 Jul | **VERIFY OWNERSHIP.** On-prem Grafana is platform (INFRA-1520), and alerting was substantially reworked 24 Aug. Likely ours, possibly already fixed. |
| **INFRA-1588** Grafana → Freshservice, cloud + on-prem | In Progress | 18 Aug | **RECONCILE.** Overlaps INFRA-1657/1658 (on-prem alerts reached nobody; Alertmanager absent; fixed dev + QA 24 Aug, prod pending). Decide whether 1588 is now the cloud half only. |
| **INFRA-1628** K8s + Talos upgrade, all three | In Progress | 5 Aug | **KEEP, but question the owner.** Real work with a reworked ladder (Talos 1.11.1 → 1.13, K8s 1.32.0 → 1.35; clusters confirmed at v1.32.0 today). It is pure platform, and the new split puts Idris on the application side. INFRA-1626 folds into this. |
| **INFRA-1473** epic: RisingWave Deployment | In Progress | 22 May | Stays open; it is the parent. |

---

## Tickets that do not exist and should

1. **Containerise the RisingWave workload.** The single highest-leverage item, the one thing
   the platform genuinely cannot supply, and **there is no ticket for it.** Everything
   downstream waits on it.
2. **`deploy/` base + overlays for the containerised workload.** INFRA-1635 exists but is
   scoped to the smoke payload — `PIPELINE_DIR` still points at it.
3. **An ECR repository for the RW image.** The existing push role is bolted to
   `risingwave/etl-pipeline`'s ARN and will not cover a second image.

---

## Next steps, in order

1. **Verify and close INFRA-1637.** Security, claimed done, and the revocation half is
   unproven. Nothing else outranks it.
2. **File and start the containerisation ticket.** No ticket, highest leverage.
3. **INFRA-1501** — bring `pg-postgresql` under GitOps. Directly implicated in a nine-day
   silent outage.
4. **Decide INFRA-1644** — the dev pipeline's future. That one decision closes 1489 and 1490
   and unblocks re-scoping 1477.
5. **Sign in to Argo CD on QA** and run `scripts/argocd-can-i.sh op-qa --role app-viewer`.
   This is the acceptance test for INFRA-1639 and takes five minutes.
6. **INFRA-1500** — small cleanup, verify then delete.
7. **INFRA-1628** — continue, or hand back to platform. Needs a decision, not effort.

**Close on the call:** 1626, 1591, 1489, 1490, and the delivered half of 1488. That is five
off his board for roughly ten minutes of agreement.
