# On-prem application delivery — CI/CD and onboarding

**Applies to:** every application deployed to the on-prem Talos clusters —
`op-usxpress-dev` (10.10.82.50), `op-usxpress-qa` (10.10.82.51),
`op-usxpress-prod` (10.10.82.52). RisingWave is the first consumer; nothing here is
specific to it.

**Not this path:** applications being lifted from cloud EKS. Those go through DX /
MageRunner. Ask before assuming.

Status as of 2026-08-18: the platform side is built and proven on QA and prod. The
first app has not yet been onboarded end to end.

---

## 1. The model

**Build once. Promote by digest. Never rebuild between environments.**

```
  commit ──► GitHub Actions ──► ECR (by digest) ──► PR bumps QA overlay
   (app)      (GitHub-hosted)     064859874041           (app)
                                                            │
                                          Argo CD on QA syncs automatically
                                                            │
                                       PR bumps prod overlay — the SAME digest
                                                            │
                                     Argo CD on prod — synced by a human, never automatically
```

The guarantee this buys: what runs in production is provably the artefact that passed in
QA, because it is the same bytes. A tag can be moved and a rebuild can pick up a different
base image; a digest cannot.

Builds run on **GitHub-hosted runners**. The clusters only ever pull. Nothing in CI needs
network access to on-prem, and no CI credential exists inside a production cluster.

### 1.1 Two shapes

| Shape | Use for | Runs as |
|---|---|---|
| **Service** | long-running HTTP or gRPC workloads | Deployment + Service, optionally exposed |
| **Job** | migrations, SQL pipelines, batch, scheduled work | Job as an Argo CD **sync hook**, so it re-runs on every sync and its logs appear in the Argo UI |

The Job shape matters more than it looks. Many on-prem dependencies — databases, message
brokers, RisingWave's SQL frontend — are `ClusterIP` with no external route. A Job running
*inside* the cluster reaches them over cluster DNS. That is why deployment work runs in the
cluster and not in CI.

---

## 2. Environments

| | dev | QA | prod |
|---|---|---|---|
| Cluster | op-usxpress-dev | op-usxpress-qa | op-usxpress-prod |
| AWS account | 700736442855 | 527101283767 | 937464026810 |
| OIDC issuer | d3a7wcnazdrd6p.cloudfront.net | d2t7d36wmf0hbm.cloudfront.net | d3rxit8f4yvshu.cloudfront.net |
| Argo CD sync | — | automated, self-heal | **manual only** |
| Human access | certs (break-glass) | AWS SSO | certs (break-glass) |

Each cluster's IAM roles live in **its own account**. There is no cross-cluster bridge.
The one shared resource is the ECR registry, `064859874041`, in us-east-1 and us-east-2.

Prod's Argo CD Applications have **no** `automated` sync policy. A merge does not deploy to
production; a person does.

---

## 3. Who does what

### 3.1 Platform owns

| Thing | Detail |
|---|---|
| The `app-<name>` namespace | created by Flux, with ResourceQuota, LimitRange, PodSecurity `restricted`, Istio ambient enrolment |
| ECR repository | IMMUTABLE tags, scan-on-push, lifecycle (untagged >7d, keep 50) |
| The push credential | a GitHub OIDC role scoped to **one** repo, **one** branch, and **one** repository ARN |
| Registry pull | `ecr-credentials-sync` writes `ecr-pull-secret` into every namespace every 5 minutes and patches every ServiceAccount |
| Argo CD | the install, the `apps` AppProject, the ApplicationSet entry |
| Secret **delivery** | AWS Secrets Manager → External Secrets → a Kubernetes Secret |
| Guardrails | Kyverno policies on registry and digest |
| Networking | DNS, TLS, ingress (HTTP via Istio; L4/TCP-SNI where a protocol needs it) |

### 3.2 The application team owns

| Thing | Detail |
|---|---|
| Application code and `Dockerfile` | |
| The manifests in `deploy/` | base + one overlay per environment |
| Which digest goes where | by opening and merging the promotion PRs |
| Secret **values** | the platform delivers them; it does not choose them |
| Whether the deploy actually worked | a green sync is not a working deploy — see §7 |

The split is deliberate: **platform owns the path, the app owns the payload.** An app team
cannot create a namespace, cannot deploy outside their own, and cannot bypass the registry.
Equally, the platform does not review application code or decide when a release ships.

---

## 4. Onboarding a new application

### 4.1 What the app team sends — one message, four facts

1. **Application name** — becomes namespace `app-<name>`
2. **GitHub repository and branch** to trust for pushing (e.g. `variant-inc/foo` on `master`)
3. **Shape** — service or job
4. **Dependencies** — which in-cluster services, which secrets, whether it needs to be reachable from outside

### 4.2 What platform does — six changes, ~1 hour

| # | Repo / system | Change |
|---|---|---|
| 1 | ECR account IaC | repository + GitHub OIDC push role |
| 1b | ECR account IaC | **repository policy allowing the cluster accounts to PULL** |
| 2 | `iaac-talos-flux-platform` (per env branch) | `infrastructure/app-namespaces/app-<name>.yaml` |
| 3 | `iaac-talos-flux-platform` (per env branch) | ApplicationSet entry — four lines |
| 4 | AWS Secrets Manager | per-environment secret paths |
| 5 | `iaac-talos-flux-platform` (per env branch) | **Argo CD repo credential** — a `repo-creds` secret scoped to `https://github.com/variant-inc`, from Secrets Manager via ExternalSecret. One-time per cluster, not per app |
| 6 | — | hand back the ECR URI and the push role ARN |

⚠️ **Step 1b is not optional and is invisible until the first pull.** ECR authorises
per REPOSITORY. A new repository has no policy, so no other account can read it, and the
kubelet reports `403 Forbidden` on the manifest HEAD — which reads as a broken pull secret.
It is not: the pull secret authenticates to the *registry*. Push is unaffected, because the
GitHub OIDC role is in the same account as the registry and IAM alone covers it. This cost
a full sync on 2026-08-20 and no earlier test could have caught it — the 2026-08-18 pull
test used `lazy/api`, which already had a permissive policy.

⚠️ Step 5 is **done on op-usxpress-qa as of 2026-08-20** (INFRA-1647), by deploy key
rather than the intended org GitHub App — see `ARGOCD-GIT-CREDENTIAL.md`. Prod still has
no Git credential.

⚠️ Superseded note, kept for the record — Step 5 was **not yet done on any cluster**. Argo CD currently holds no Git
credential at all, so it cannot read a private application repository. An app team can do
everything correctly and still see `ComparisonError: authentication required`. This was
invisible until the first real deploy, because the Application pointed at a path that did
not exist and never got as far as authenticating.

⚠️ **Per-environment branches are copies of one another.** Every cluster-specific value —
account ID, role ARN, OIDC issuer, hostname, node address — must be changed on each branch.
Four defects from exactly this were found on 2026-08-18. The failure mode is always silent:
the Flux Kustomization reports `Ready` while the workload cannot authenticate or route.

### 4.2b Two settings that decide whether you can debug this later

**Argo CD needs a Git credential per cluster.** QA has one as of 2026-08-20: a repository
**deploy key**, `secret-type: repository`, matched to one exact `ssh://` URL. It is owned by
the repository — no expiry, unaffected by offboarding, and creating one needs admin on that
repo rather than ownership of the org. The trade is scope: per-repository, so app number two
needs its own until an org GitHub App exists (`REQUEST-GITHUB-APP-OWNER.md`). A fine-grained
PAT cannot meet "not tied to a person" — it is owned by a user account even when the
resource owner is the org.

⚠️ **A VirtualService on these clusters needs
`external-dns.alpha.kubernetes.io/target`.** external-dns takes the record's target from the
ingress gateway's LoadBalancer address, and `istio-ingressgateway` here is ClusterIP with
`hostNetwork` — there is no address to take. Without the annotation the route is created, Flux
reports Ready, and the hostname never resolves. Copy the value from a route that works
(`risingwave-dashboard` on op-qa) rather than choosing node addresses.

⚠️ An `https://` Application will not match an `ssh://` credential, and the failure is
`authentication required` — identical to having no credential at all. The ApplicationSet
entry and the credential URL must move together, in one PR.

**Set `hook-delete-policy: BeforeHookCreation,HookSucceeded` and lower the ApplicationSet
retry limit.** With `BeforeHookCreation` alone, Argo CD's five automatic retries each destroy
the previous attempt's pod and logs, so a failing hook deletes its own evidence — three
separate attempts to read one failure on 2026-08-20. With `HookSucceeded` alone, a retained
failed Job blocks the next sync with `AlreadyExists`, and successes delete the evidence *of
success*. Both, plus a low retry limit, gives: a failure stops at once and persists until
someone deliberately re-syncs.

### 4.2c Verify the credential opens the thing, before the app does

`SecretSynced` proves the sync ran. `Synced Healthy` proves manifests match git. Neither is a
statement about whether the value works — on 2026-08-20 four consumers held identical
passwords and none of them matched the database.

```bash
KUBECONFIG=$HOME/.kube/op-usxpress-qa-sso.yaml \
  bash scripts/check-postgres-secret-usable.sh op-usxpress-qa-sso risingwave \
    op-usxpress-qa/risingwave/postgres usx-qa
```

Run `scripts/check-foreign-cluster-ids.sh <platform-repo> <branch> --diff origin/<branch>`
before every platform PR, and `scripts/verify-overlay-endpoints.sh` on the overlay in the
same pass — it resolves every
`*.svc.cluster.local` name against the target cluster and lists the real services when one
misses.

### 4.3 What the app team does

1. Copy `app-template/job/` or `app-template/service/`
2. Set `ECR_REPOSITORY` and `PUSH_ROLE` in `.github/workflows/build-and-push.yml`
3. Set `branches:` in that workflow to the repo's **actual default branch** — several repos
   here use `master`, and the OIDC trust must match exactly or STS denies with a message
   that reads like a permissions fault
4. Push. The workflow builds, pushes by digest, and opens the QA promotion PR
5. Merge it; watch Argo CD
6. For prod: a second PR moving the same digest, then a manual sync

---

## 5. Rules that are enforced, not advised

Kyverno rejects manifests that break these:

1. **Images come from `064859874041.dkr.ecr.us-east-2.amazonaws.com`.**
2. **Images are pinned by digest.** `:latest` and `:v1.2.3` are both refused.

Structural, not policy:

3. **You cannot deploy outside your namespace.** The `apps` AppProject permits `app-*` only.
4. **You cannot create a namespace.** Every Application sets `CreateNamespace=false`.

Both Kyverno policies currently run in `Audit` — they record violations without blocking.
They flip to `Enforce` once the first application has deployed cleanly, so the first thing
they block is a mistake rather than the pipeline's own bring-up.

---

## 6. Nothing environment-specific in the image

The rule that decides whether promotion actually works. If a value differs between QA and
prod it does not belong in the image — not in a config file, not in a baked-in default, not
in SQL.

| Value | Where it goes |
|---|---|
| Hostnames, ports, topic and queue names | ConfigMap in `deploy/overlays/<env>/` |
| Credentials, connection strings, API keys | Secrets Manager → `ExternalSecret` → Secret |
| Log level, feature flags, environment name | ConfigMap in the overlay |

Inline a `dev-` prefixed topic and the artefact built in dev will point at dev's
dependencies when it runs in QA. It will not fail loudly. It will succeed against the wrong
thing, which is worse.

---

## 7. Troubleshooting — and the boundary

Two controllers, two domains, deliberately separated so an app team can diagnose their own
deploy without platform access:

- **Your application** → **Argo CD**. `argocd app get <name>`, or the UI.
- **The platform** (Istio, cert-manager, External Secrets, the registry credential sync) →
  **Flux**. `flux get kustomizations`. Ask us.

If your app is broken, start in Argo CD. If half the cluster is broken, it is ours.

| Symptom | Look at |
|---|---|
| Image won't pull | `kubectl -n app-<name> get secret ecr-pull-secret` — refreshed every 5 min |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` in CI | branch mismatch against the role's trust policy, far more often than a real permissions problem |
| Argo CD refuses the Application | destination namespace isn't `app-*` |
| Admission rejected the pod | Kyverno — a tag instead of a digest, or a non-ECR image |
| `CreateContainerConfigError` | a ConfigMap or Secret named in `envFrom` doesn't exist yet |
| Sync green, nothing happened | read the Job's **logs**, not its exit status |

### A green status is not a working system

This has cost us real time, repeatedly, and it is the single most useful thing on this page:

* A Flux `Kustomization` reporting `Ready` means the manifests were **applied**, not that
  the workload succeeded. A CronJob can apply cleanly and fail every run.
* An `ExternalSecret` reporting `SecretSynced` means the sync **ran**, not that the value
  is correct.
* A `GitRepository` can report `Ready` while serving a two-day-old artefact, if the fetch
  is failing but the last good artefact is still cached.
* An Argo CD sync reports that Kubernetes accepted your manifests and pods became ready.
  It cannot tell you the work happened.

Always verify against the thing that does the work: the job log, the object that should
have been created, the row that should have been written.

---

## 8. Cost of onboarding the next app

| Task | Effort |
|---|---|
| ECR repository + push role | ~10 min, IaC |
| Namespace manifest, per environment | ~5 min each |
| ApplicationSet entry, per environment | 4 lines each |
| Secrets Manager paths | ~10 min |
| App-side scaffold from the template | ~30 min |

The design intent: onboarding an app is **data**, not new infrastructure. One namespace
file and one ApplicationSet entry per environment. If it ever requires a new Kustomization
or a new controller, something has drifted from this design.
