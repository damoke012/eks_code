# Prod build — zero-manual-intervention inventory and gaps

**Owner:** Doke · **Tickets:** INFRA-1589 (automation), INFRA-1621 (prod gaps)
**Status as of 2026-07-22.** Supersedes the "Summary" section of `iaac-full-teardown/REBUILD-RUNBOOK.md`,
which understates what still needs a human.

## Why this document exists

The rebuild runbook claims *"Cluster + platform + storage + IRSA + talosconfig + grafana admin →
100% IaC, zero manual"* with Azure-AD SSO as the single exception. **That claim has never been
demonstrated** — QA was never torn down and rebuilt, and QA will not be torn down. Prod's first
build is therefore the first real execution of this path.

Worse, INFRA-1623 exposed a failure class the runbook does not model at all. Two independent
defects sat in the etcd-backup path for 13 days:

1. Terraform created the SM secret **wrapper** but never wrote its **value** → `PLACEHOLDER_POPULATE`.
2. The `op-qa` Flux branch, cut from `op-dev`, still pointed talosctl at **dev's VIP** `10.10.82.50`.

Neither was a missing manual step. Both were *fully automated code that was wrong*. Every
deploy reported success. The only honest signal was the absence of an artifact in S3.

**Design principle that follows:** automation removes toil, it does not confer correctness.
Every automated step needs a gate that proves the *artifact*, not the *exit code*.

---

## A. Manual interventions still required for a prod build

| # | Step | Why it's manual | Can it be automated? |
|---|---|---|---|
| A1 | Entra app registration for Grafana SSO (client_id/secret) | Entra-owned; Doke has no Azure access | **No** — cross-team. Grafana boots without it (admin login works). Keep the TF placeholder + `ignore_changes`. |
| A2 | Octopus prod environment + ~29 `TF_VAR_*` | Octopus is config-as-data, not in git | **Yes** — script it, same shape as `add-qa-vars.py`. **Not yet written.** |
| A3 | Prod hardware / vSphere capacity | Physical | No |
| A4 | `op-prod` Flux branch + `clusters/op-usxpress-prod/` | Branch-per-env topology | **Yes, by eliminating it** — see section C |
| A5 | Flux bootstrap PAT | Only used at `flux bootstrap` | Accept; short-lived, single use |
| A6 | GitHub deploy keys (e.g. RisingWave repo → SM) | Per-repo secret | **Yes** — TF-managed `github_repository_deploy_key` + SM write |

**A2 is the one that bites.** Octopus variables are the single largest body of prod config
that exists nowhere in git. If they're hand-entered, prod gets a fresh chance at exactly the
kind of typo this document is about. Script it and diff it against QA's set.

---

## B. Verification gates — prove the artifact, not the exit code

Each gate must fail loudly. "Deploy succeeded" is not a gate.

| Gate | Command | Pass condition |
|---|---|---|
| B1 talosconfig is real | `aws secretsmanager get-secret-value --secret-id op-usxpress-prod/talosconfig --query SecretString --output text \| head -c 20` | Starts `context:`, not `PLACEHOLDER` |
| B2 SM value == mounted value | `diff <(aws ... --output text) <(kubectl -n etcd-backup get secret talosconfig -o jsonpath='{.data.config}' \| base64 -d)` | Only a trailing-newline delta |
| B3 talosctl reaches **this** cluster | `TALOSCONFIG=<SM value> talosctl -n <prod VIP> -e <prod VIP> version` | Server tag returned |
| B4 **etcd snapshot exists in S3** | `aws s3 ls s3://etcd-snapshots-op-usxpress-prod --recursive` | ≥1 object, non-zero size, timestamp < 2h old |
| B5 no foreign-env strings | `git grep -nE "op-usxpress-(dev\|qa)\|10\.10\.82\.(50\|51)" origin/op-prod` | **Zero hits** |
| B6 ExternalSecrets are *valid*, not just synced | per-consumer functional check | See [[eso-secretsynced-not-content-check]] |
| B7 Flux applied the commit you merged | `flux get kustomizations` revision == merged SHA | Exact SHA match **before** re-testing anything |

**B4 and B5 are the two that would have caught INFRA-1623.** B7 is the one that produced a
false negative during the fix itself — the first post-merge job run used the stale spec and
looked identical to a real failure.

**B6 restated, because it keeps recurring:** a green `SecretSynced` proves the sync
executed. It says nothing about whether the value works. It has now misled us twice — Wiz
(6-char placeholders synced green) and QA etcd (`PLACEHOLDER_POPULATE` synced green).

---

## C. The structural fix — kill branch-per-env

**Root cause of the dev-VIP bug:** `op-qa` is a *copy* of `op-dev`. Every environment-specific
literal in a shared manifest is a latent bug that only surfaces when something visibly breaks.

Known instances found so far, each discovered by an incident rather than by design:

| Found | Instance | Status |
|---|---|---|
| 2026-07-14 | grafana ExternalSecrets → `op-usxpress-dev/platform/grafana*` | Fixed |
| 2026-07-14 | `external-dns txtOwnerId=op-usxpress-dev` | **STILL OPEN** — QA claims DNS ownership as dev |
| 2026-07-22 | etcd-backup `--endpoints/--nodes=10.10.82.50` | Fixed (PR #77) |

`op-prod` cut the same way inherits the same class. The fix is Flux `postBuild.substituteFrom`
against a per-cluster ConfigMap, so manifests carry **no** environment literals:

```yaml
# iaac-talos-flux-cluster: clusters/op-usxpress-prod/flux-system/cluster-vars.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-vars
  namespace: flux-system
data:
  cluster_name: op-usxpress-prod
  cluster_vip:  "10.10.82.XX"     # prod VIP
  env:          prod
  aws_account:  "<prod account>"
  oidc_issuer:  "<prod cloudfront domain>"
```
```yaml
# every Kustomization
spec:
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-vars
```
```yaml
# manifests become env-agnostic
- --endpoints=${cluster_vip}
- --nodes=${cluster_vip}
```

End state: **one branch** for all clusters, differing only by ConfigMap. Branch-copy drift
becomes structurally impossible, and B5 becomes trivially true.

> ⚠️ **Landmine.** `postBuild` substitutes `${...}` across the *whole* built manifest. Grafana
> dashboard ConfigMaps are full of `${datasource}`, `${interval}` etc. and Flux will happily
> blank them. Either escape as `$$` or leave dashboard Kustomizations off `substituteFrom`.
> Roll this out per-Kustomization, verifying rendered output each time — not repo-wide in one PR.

**Migration order:** op-qa first (safe, not torn down) → verify identical rendered output →
op-dev → then cut op-prod from the unified branch.

---

## D. Alerting — the gap that let this run 13 days

Both defects were invisible because the only symptom was `BackoffLimitExceeded` in a namespace
nobody watches. **Nothing alerts on backup staleness today.**

Manifest: `wip/qa-cluster-standup/alerts/etcd-snapshot-age.yaml` (PrometheusRule).
Covers snapshot staleness, job failure, and — critically — the CronJob *disappearing*
(`absent()`), which a naive threshold alert misses entirely.

Deploy to `op-qa` **and** `op-dev`; prod inherits it via section C.

---

## E. Ordered plan to "prod is zero-manual"

| # | Task | Blocks prod? | Effort |
|---|---|---|---|
| E1 | Deploy etcd-snapshot-age alert to op-qa + op-dev | No, but do first — cheap, stops the bleeding | S |
| E2 | `git grep -n "op-usxpress-dev" origin/op-qa` → fix every hit (incl. external-dns txtOwnerId) | **Yes** | S |
| E3 | `postBuild.substituteFrom` rollout, per-Kustomization, op-qa first | **Yes** — this is the prod insurance policy | M |
| E4 | Script prod Octopus vars (model on `add-qa-vars.py`), diff vs QA | **Yes** | S |
| E5 | Write `prod.tfvars`; `enable_irsa=true` (never commit `false` — see landmine in STATE.md) | **Yes** | S |
| E6 | Cut `op-prod` + `clusters/op-usxpress-prod/` from the unified branch | **Yes** | S |
| E7 | Run gates B1–B7 as a prod acceptance checklist | **Yes** | S |
| E8 | TF-manage deploy keys (A6) | No | M |

**E3 is the highest-value item in this document.** Everything else is a checklist; E3 removes
the failure mode that generated the checklist.

## Honest status

- **Automated and proven on QA:** Talos, Flux, IRSA, storage, talosconfig value, grafana admin
  password, etcd snapshots (as of 2026-07-22).
- **Automated but never proven:** the full teardown→rebuild path. Prod is the first execution.
- **Not automated:** A1 (won't be), A2/A4/A6 (should be — E4/E3/E8).
- **Not covered by any automation:** environment-correctness of copied manifests. That is what
  section C fixes and section B gates.
