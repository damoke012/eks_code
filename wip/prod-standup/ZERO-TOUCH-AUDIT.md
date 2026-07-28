# Will `TfApply=true` give a working prod platform with no manual intervention?

**No.** Not close, today. This is the component-by-component evidence.

Sources: `clusters-op-usxpress-prod/flux-system/infra.yaml` (what prod actually deploys),
`wip/onprem-troubleshooting/QA-CLUSTER-BOOTSTRAP-CHECKLIST.md` (what QA actually needed),
`deploy/terraform/` on `refactor/multi-env-parameterization`.

---

## Headline

Right now `TfApply=true` produces **13 Talos VMs and nothing else**. Not a partial
platform — no Flux, therefore no Kustomizations, therefore no ESO, Grafana, Velero,
etcd-backup, Argo CD, Istio, Rook. Terraform exits 0 and Octopus goes green.

Even after the Flux gap is closed, **21 of the 32 platform components do not exist as
manifests** in prod's `infra.yaml` — they are a comment listing their names.

---

## A. What prod's `infra.yaml` actually contains

**Phase 1 — 11 real Kustomizations, AWS-free, would reconcile once Flux exists:**

| Component | Depends on |
|---|---|
| cert-manager | — |
| trust-manager | cert-manager |
| trust-manager-bundle | trust-manager |
| gateway-api | — (upstream GitRepository) |
| keda | — |
| kyverno | — |
| kyverno-policies | kyverno |
| reloader | — |
| cilium-lb | — |
| cilium-hygiene | — |
| pod-identity-webhook | cert-manager |

**Phase 2 — 21 components that exist ONLY as a comment (lines 195–220):**

```
istio-namespace, external-secrets, cert-manager-issuers, external-secrets-config,
istio-csr, istio-base, istio-istiod, istio-cni, istiod-health, istio-ztunnel,
istio-ingress, prometheus, external-dns, grafana, prometheus-rules, velero,
etcd-backup, local-path-storage, rook-ceph-operator, rook-ceph-cluster,
argocd, argocd-config
```

⚠️ **The header says "uncomment as a unit" but there is nothing to uncomment.** The file
holds a *list of names*, not commented-out YAML. All 21 Kustomization blocks — with correct
`dependsOn` ordering, intervals, timeouts and the `wait:` semantics below — must be authored
from op-qa's `infra.yaml`. That is the single largest piece of remaining work.

**Everything you named is in that missing set:** Velero, ESO, Argo CD, etcd-backup,
Grafana, all nine Istio components, Rook-Ceph.

---

## B. Manual steps the QA checklist documents as REQUIRED

The checklist's own mission statement is *"Cluster comes up automatically from IaC **+ a
single planned Octopus runbook sequence**"* — so a hands-off run was never the design.
Two steps are explicitly interactive:

### Phase 7 — Seed cross-cluster ESO token (Octopus UI)
> *Navigate to OnPremise space → onprem-platform-bootstrap project → Run the **Seed
> Cross-Cluster ESO Token** runbook against the new cluster as target.*

Until it runs, `clustersecretstore/cloud-eks` stays `Ready=False`. Any ExternalSecret bound
to it never syncs. The checklist lists *"OnPremise Octopus space + Seed Cross-Cluster ESO
Token runbook IaC'd"* as an **open gap**.

### Phase 8 — Restore cross-cluster ExternalSecrets (git edit)
> *Uncomment the ExternalSecret manifests that depend on `cloud-eks` CSS, commit + merge.*

A human editing YAML mid-bootstrap, by design.

### Prerequisites that must pre-exist
- OnPremise Octopus space exists **before** Phase 6
- `onprem-platform-bootstrap` project deployed there
- `Seed Cross-Cluster ESO Token` runbook configured **and tested**

**To be zero-touch these must become an Octopus deployment step or a Terraform provisioner
in the same pipeline, not a separate human-run runbook.**

---

## C. Secret seeding — 4 secrets, all seed-first

| Secret | Consumer | How |
|---|---|---|
| `op-usxpress-prod/talosconfig` | TF import → etcd-backup | create-secret PLACEHOLDER, ARN → `TF_VAR_talosconfig_secret_arn` |
| `op-usxpress-prod/platform/grafana` | Grafana admin | same, `TF_VAR_grafana_admin_secret_arn` |
| `op-usxpress-prod/platform/grafana/azure-ad` | Entra SSO | same, `TF_VAR_grafana_azure_ad_secret_arn` |
| `op-usxpress-prod/platform/argocd` | Argo CD admin | **ESO reads it — must hold a REAL value, not a placeholder** |

The first three are TF inputs (see G4 in [AUTOMATION-GAPS.md](AUTOMATION-GAPS.md)). The
**argocd one is different**: nothing in Terraform creates it, ESO just reads it. If it is
absent the ExternalSecret fails; if it holds `PLACEHOLDER` the ExternalSecret goes
**green with an unusable credential** — the `SecretSynced ≠ valid content` trap that has
already bitten Wiz and QA etcd-backup.

---

## D. Config deltas vs the checklist's post-incident minimums ⚠️ NEEDS A DECISION

The checklist sets floors learned from real incidents. Prod's staged variables:

| Setting | Checklist minimum | Prod config | Status |
|---|---|---|---|
| CP RAM | 8 GB (post 2026-06-17 OOM cascade) | 16384 MB | ✅ |
| Worker count | ≥ 7 | 10 | ✅ |
| Worker RAM | **12 GB** (post 2026-06-17, was 4 GB) | system pool **8192 MB** | ⚠️ **BELOW** |
| | | platform 16384 / application 32768 | ✅ |
| `etcd_quota_backend_bytes` | ≥ 8 GB (default 2 GB causes disk pressure) | **not in prod's 29 vars** | ⚠️ **UNSET** |

Both were inherited by mirroring QA, so QA likely shares them. The system pool may
legitimately run lighter than the 12 GB floor written before the three-pool split existed —
but that is a judgement to make deliberately, not by inheritance. `etcd_quota_backend_bytes`
needs checking against the module default before the first apply, because raising it later
means a machine-config change on a live cluster.

---

## E. Ordering subtleties that break bootstrap if copied wrong

From the checklist, learned the hard way on dev:

- **`external-secrets-config` must be SPLIT** — `default` CSS (AWS SM, self-sufficient) in
  one Kustomization, `cross-cluster-eso` (`cloud-eks` CSS) in another.
- **`cross-cluster-eso` needs `wait: false`.** Every other Kustomization is `wait: true`.
  Get this wrong and bootstrap deadlocks: the Kustomization waits on a CSS that cannot go
  Ready until a later phase seeds its token.
- `app-secrets/` at first deploy may contain **only** ExternalSecrets using the `default`
  CSS.

Prod's phase-2 comment lists `external-secrets-config` but **not** `cross-cluster-eso` —
so the split is missing from the plan and would be reintroduced as a bug.

---

## F. What must be true for a genuinely hands-off run

| # | Gap | Type |
|---|---|---|
| 1 | Flux bootstrap automated (`terraform_data` + `kubectl apply -k`) | code, iaac-talos |
| 2 | 21 phase-2 Kustomizations authored into prod `infra.yaml`, incl. the `cross-cluster-eso` split + `wait: false` | manifests |
| 3 | 4 SM secrets ensure-and-export in `deploy.ps1` (+ `restore-secret` for rebuilds) | code, deploy.ps1 |
| 4 | Argo CD admin secret holds a real value, not a placeholder | data |
| 5 | Cross-cluster ESO token seeding folded into the pipeline (today: manual Octopus runbook) | code/runbook |
| 6 | Phase-8 "uncomment ExternalSecrets" eliminated — ship them enabled, ordered correctly | manifests |
| 7 | `enable_irsa=true` + prod account credentials (G2/G3) | config |
| 8 | `op-prod` branch literals fixed — else ESO reads QA's secrets, Velero writes QA's bucket, etcd snapshots land in QA's bucket, all green | script, ready |
| 9 | etcd-backup CronJob endpoints = `10.10.82.52` (inherited `.51` from op-qa) | manifests |
| 10 | Worker RAM / etcd quota decisions above | config |

---

## Recommendation

Two coherent options:

**Apply phase 1 now.** You get 13 VMs and a bare Talos cluster — a real checkpoint proving
vSphere placement, the prod state bucket, Talos bootstrap and etcd quorum, on infrastructure
nobody has built from scratch before. Then close 1–10 against a cluster that exists. Nothing
in that list is made harder by the cluster already running.

**Or hold** until 1–10 are done and run once. That first run then exercises infrastructure
*and* the entire platform simultaneously — harder to debug, and two silent-failure gaps
already surfaced in a single day from paths that only execute on a from-scratch build.

Either way item 2 — authoring 21 Kustomizations — is the bulk of the work and is not
blocked by anything. It can start immediately.
