# Message to Idris — 2026-07-23

Two patches attached. Both apply with `git am`, both keep your authorship on your commits
and mine on mine.

**Access:** I only have `pull` on `iaac-risingwave-onprem` and `iaac-argocd-onprem`, so I
can't open PRs myself — that's why these are patches rather than branches. Could you add
`dare-x` as a writer on both? Otherwise every review round costs an extra handoff.

---

## 1. RisingWave → QA — `qa-review-fixes.patch` (4 commits)

```bash
cd <iaac-risingwave-onprem>
git checkout feat/qa-platform-layer
git am < qa-review-fixes.patch
terraform -chdir=terraform fmt -check
```

Your branch was solid — ExternalSecrets throughout with nothing committed, `ceph-block`,
`pool: platform` on every component, RW's own Prometheus/Grafana correctly left out, image
pinned. The three IRSA diffs were exactly right. Six things needed fixing.

**The one worth understanding, because it would have shipped silently.**
`kustomization.yaml` sets `namespace: risingwave`, and kustomize's namespace transformer
rewrites `metadata.namespace` on **every** resource — including `velero-schedule.yaml`.
Velero's controller only watches its own namespace, so that Schedule would have been
created, reported no error, and **never taken a backup**. Since its whole purpose is
surviving a teardown, that's the worst thing to have failing invisibly. There's no clean
per-resource exemption from the transformer, so it moved to `iaac-talos-flux-platform`
`op-qa` alongside the rest of Velero — already merged and verified live.

**The rest:**

- **PodMonitors added.** Dev's RisingWave was scraped by RisingWave's *own* Prometheus via
  `extraScrapeConfigs`. Dropping that stack was right, but it left nothing scraping RW at
  all, so the dashboard would have rendered empty. Ports carried over from dev: meta 1250,
  frontend 8080, compute 1222, compactor 1260.
- **`terraform/secrets.tf` — all five SM secrets.** `manifests/op-usxpress-qa/` reads
  `op-usxpress-qa/risingwave/*` and none of those existed. Four are now Terraform-generated
  (`postgres`, `root`, `svc-reporting`, `secret_store_private_key`); only
  `console_license_key` is external. Note `secret_store_private_key` has
  `ignore_changes` — RisingWave encrypts stored secrets with it, so rotating it would
  orphan everything already encrypted.
- **`deploy/deploy.sh` cut down to Terraform only.** It called
  `aws eks update-kubeconfig --name op-usxpress-qa` (these are on-prem Talos — no EKS
  cluster by that name), ran `kubectl apply -k` (Flux owns manifests), passed `-var` for two
  variables `variables.tf` doesn't declare, and **never passed `-var-file`**, so
  `op-usxpress-qa.tfvars` would have been ignored entirely. That's why this Terraform has
  never applied anywhere — the dev state bucket contains no RisingWave state.
- **Backend isolation** — `backend-dev.hcl` / `backend-qa.hcl`, and `main.tf`'s hardcoded
  backend blanked so a missing `-backend-config` fails loudly instead of silently resolving
  to another environment.
- **`s3_bucket_prefix` is the full bucket name**, not a prefix, so it's
  `risingwave-state-op-usxpress-qa`. My original brief said `"risingwave-state"` — my error,
  sorry.
- Dropped `risingwave-dev-dashboard.json` (1.15 MiB, over the ConfigMap limit; the
  documented workaround was a manual Grafana UI import, which this repo shouldn't need).

**Verified:** `terraform plan` against live QA resolves the OIDC provider, trust sub
`system:serviceaccount:risingwave:risingwave`, role `op-usxpress-qa-risingwave` —
**20 to add, 0 to destroy.** Provider pinned `aws v5.100.0`, `random v3.9.0`.

**Still open on your side:**

1. **`risingwave-user-dashboard.json` pins datasource UID `PBFA97CFB590B2093`** — that's
   RisingWave's own Grafana. QA's platform Grafana has a different UID, so every panel will
   read "Datasource not found". Needs the platform UID or a datasource template variable.
2. **From Tim, before the CR is final** — operator chart version pin, component sizing, and
   S3 retention. Sizing matters most: `replicas: 1` on meta and frontend means no HA, and
   under "QA mirrors prod" that shape propagates straight to prod.
3. **Scope question** — `rw-root-bootstrap-job.yaml` and
   `rw-service-accounts-bootstrap-job.yaml` create SQL users. That reads as app layer in
   Tim's namespace rather than platform. Worth confirming with him.
4. **Octopus** — there are two projects, `iaac-risingwave-onprem` and `iaac-risingwave`,
   both still described "Cloned from Default Project". `deploy.sh` now needs
   `ENVIRONMENT=op-usxpress-qa`. Which project is real, and does it have a QA environment?

**Mine, not yours:** the deploy key and
`iaac-talos-flux-cluster: clusters/op-usxpress-qa/risingwave.yaml`. Your PR can merge
first — it just won't reconcile until that lands.

---

## 2. Argo CD — `argocd-iac.patch` (1 commit)

```bash
cd <iaac-argocd-onprem>
git checkout main
git am < argocd-iac.patch
kubectl kustomize manifests/op-usxpress-dev   # sanity check
```

**Kept your work.** `argocd-admin-externalsecret.yaml`, `argocd-git-externalsecret.yaml`,
`namespace.yaml`, and all the `argocd-cm` controller tuning. You were right and I was wrong
on two things I'd guessed: the ClusterSecretStore is `default` (there is no
`aws-secretsmanager`) and the cluster serves `external-secrets.io/v1` only — my drafted
ExternalSecret would not have applied. Deleted mine, kept yours.

Your `argocd-cm-patch.yaml` is folded into the HelmRelease `values.configs.cm` — under Helm,
`argocd-cm` is rendered at runtime, so a kustomize patch has no target. Your
`resource.exclusions` list is **merged**, not replaced: your high-churn kinds
(Endpoints/EndpointSlice/Lease/Cilium/Kyverno) plus the Flux toolkit groups.

**I removed `application-risingwave.yaml`, and I want to be straight about why.**

That Application had `project: default`, `repoURL: iaac-risingwave-onprem`,
`path: manifests/op-usxpress-qa`, `destination.namespace: risingwave`, and
`syncPolicy.automated{prune: true, selfHeal: true}` with `ServerSideApply=true`.

That's the same path Flux reconciles, in Tim's namespace. Two controllers both self-healing
the same objects fight indefinitely — each sees the other's write as drift and reverts it —
and `prune: true` means Argo CD can *delete* resources its view says shouldn't exist. Using
`project: default` also bypasses the AppProject restrictions entirely.

**RisingWave already has GitOps, and it's Flux.** That decision has been in place since
May, and today I wired `clusters/op-usxpress-qa/risingwave.yaml` to reconcile exactly that
path. Argo CD earns its place giving app teams self-service on their own namespaces, not by
taking over something that already works.

**How it's scoped now:** Argo CD may only deploy into `app-*` namespaces — the `apps`
AppProject destination glob can't match `risingwave`, `flux-system`, `velero`, `rook-ceph`,
`istio-system` or any platform namespace. The built-in `default` project is overwritten with
empty allow-lists, because it ships permissive and without that override every other
restriction is decorative. Installed by Flux from a pinned chart, ClusterIP behind Istio,
secrets via ESO.

**If there's an app-team repo that needs self-service, tell me which and I'll wire it into
the `apps` project properly** — that's the use case Argo CD is here for.

**Also removed:** `service-nodeport.yaml` (platform standard is Istio ingress; it also mapped
`:443` to a plain-HTTP `targetPort: 8080`) and the
`raw.githubusercontent.com/.../v3.4.3/install.yaml` resource — a live internet fetch inside
the reconcile path, and raw manifests take no values, so no nodeSelector and no resource
limits.

**Two open:**

1. **Chart version.** I left `7.7.11` as a placeholder and it's wrong — chart 7.x ships
   Argo CD 2.x, which would be a major *downgrade* from the v3.4.3 you picked. Use the chart
   whose `APP VERSION` is 3.4.x (see below).
2. **The `sshPrivateKey` committed in `iaac-talos-flux-platform` PR #73 is still in git
   history and needs rotating**, independently of all this. Once the RisingWave Application
   is gone, `argocd-git-externalsecret.yaml` may not be needed at all — it credentials Argo
   CD for the RisingWave repo. Happy to keep it if it's for something else.

---

## Rollout order

Dev → QA → prod for Argo CD. It's genuinely new, unlike the RisingWave work which mirrors a
running dev deployment. After it reconciles on dev, the guardrail test is the point of the
whole design:

```bash
kubectl -n argocd get appproject default -o jsonpath='{.spec.destinations}'   # must be []
argocd app create probe --repo <any> --path . \
  --dest-namespace risingwave --dest-server https://kubernetes.default.svc
# MUST be refused: "application destination ... is not permitted in project"
```

If that's **accepted**, stop — the scoping isn't working and it's the condition PR #73 was
rejected for.
