# How the on-prem platform is wired — orientation for Idris

**Written 2026-08-25.** Everything here is read off the running systems or the merged
branches, not from design intent. Where something is *not* proven it says so.

---

## 1. Three repos, three jobs, and what triggers what

The single most useful thing to hold onto: **there are two delivery controllers, and they
own different halves of the cluster.** Flux owns the platform. Argo CD owns applications.
They never touch each other's resources.

| Repo | Owns | Applied by | How it reaches a cluster |
|---|---|---|---|
| `iaac-talos` | The cluster itself — Talos nodes, networking, IAM, the AWS account | Terraform | **Octopus only.** Never a local `apply`. dev → QA → prod |
| `iaac-talos-flux-cluster` | The Flux bootstrap — the Kustomizations that point Flux at the platform repo | Flux | one repo, `master` |
| `iaac-talos-flux-platform` | Every platform component: Istio, cert-manager, External Secrets, Kyverno, external-dns, Argo CD itself | Flux | **one branch per cluster** |
| your application repo | App code, Dockerfile, and `deploy/` manifests | Argo CD | one repo, branches are environments-agnostic; the **overlay** picks the env |

### The branch model is the thing people get wrong

`iaac-talos-flux-platform` has **`op-dev`, `op-qa`, `op-prod` as parallel branches**, not
directories. A change for QA lands on `op-qa`. The same change for prod is a *separate PR*
against `op-prod`.

**These branches are copies of one another, and that has caused ten defects to date.**
Every cluster-specific value — account ID, role ARN, OIDC issuer, hostname, node address —
has to change on each branch, and when it doesn't the failure is silent: Flux reports
`Ready` and the workload cannot authenticate or route. Two examples from this month:

* op-prod's shared Gateway served **`*.op-qa.usxpress.io`** for 27 days. Nobody noticed
  because prod served no routes, so nothing ever asked it to terminate TLS.
* All five of op-prod's VirtualServices carried **op-dev's** hostnames and op-dev's seven
  worker IPs. op-prod runs its ingressgateway on ten nodes.

`scripts/check-foreign-cluster-ids.sh` scans a diff for another cluster's identifiers and
exits non-zero. Run it before pushing a platform PR.

**It is a strong prior, not a law.** op-prod's external-dns `--txt-owner-id` turned out to
be genuinely per-cluster. Check rather than assume in both directions.

### What triggers a deploy

| Change | Trigger | Latency |
|---|---|---|
| Platform manifest merged to `op-qa` | Flux polls the GitRepository, then reconciles the Kustomization | GitRepository ~1 min, Kustomization interval **10 min** |
| App digest bumped in `deploy/overlays/qa/` | Argo CD auto-sync with self-heal | ~3 min |
| App digest bumped in `deploy/overlays/prod/` | **nothing.** A human presses Sync | as long as you like |

A Flux Kustomization's default `get` output shows the Ready **message**, and its
`status.lastAppliedRevision` is what actually applied. If you are checking whether your
merge landed, read the revision — and `--force` a reconcile with an annotation rather than
waiting the ten minutes.

---

## 2. How each environment is created

| | dev | QA | prod |
|---|---|---|---|
| Cluster | `op-usxpress-dev` | `op-usxpress-qa` | `op-usxpress-prod` |
| API endpoint | 10.10.82.50 | 10.10.82.51 | 10.10.82.52 |
| AWS account | 700736442855 | 527101283767 | 937464026810 |
| Argo CD sync | — | automated, self-heal | **manual only** |
| Human cluster access | certs (break-glass) | AWS SSO | certs (break-glass) |
| ingressgateway nodes | 7 | 3 of 13 | all 10 |

**Each cluster's IAM roles live in its own account. There is no cross-cluster bridge.** The
one shared resource is the ECR registry.

The clusters are stood up by `iaac-talos` through Octopus. That path prints a Terraform
plan and reports Success **without applying** on dev and QA — `TfApply` is false everywhere
but production. A green Octopus deploy is not evidence anything changed.

---

## 3. ECR — what exists, and the one thing that will bite you

**Registry:** account `064859874041`, `us-east-2` (also `us-east-1`). Shared by all three
clusters and by the cloud EKS fleet. 517 repositories.

**For RisingWave, both of these already exist** — you do not create them:

* ECR repository **`risingwave/etl-pipeline`**
* a **GitHub OIDC push role**, scoped to one GitHub repo, one branch, and **one repository ARN**

Pull URL: `064859874041.dkr.ecr.us-east-2.amazonaws.com/risingwave/etl-pipeline`

> **If you containerise the RisingWave workload itself**, that is a *different image* from
> the ETL pipeline and needs its own repository plus a widened or additional push role.
> Ask Doke — it is not self-serve.

### Push and pull are authorised by completely different mechanisms

This is the trap, and it cost a full sync on 2026-08-20.

* **Push** works through the GitHub OIDC role, which lives in the registry's *own* account.
  IAM alone covers it. Nothing else is needed.
* **Pull is authorised per repository.** A new repository has **no repository policy**, so
  no other account can read it. The kubelet reports `403 Forbidden` on the manifest HEAD —
  which reads exactly like a broken pull secret. It is not: the pull secret authenticates to
  the *registry*, and the registry is not the thing denying you.

So a brand-new repo will accept your push and refuse every cluster's pull, silently, until
someone adds the policy. If you see `403` on a pull, ask for the repository policy before
touching anything else.

### Two more

* **The OIDC trust matches the branch exactly.** These repos use **`master`**, not `main`.
  A mismatch fails at STS with a message about the assertion subject, not about branches.
* **515 of 517 repositories grant `PutImage` to the whole organisation.** Do not model a new
  repository policy on an existing one — most of them are wrong. Being on-prem-safe depends
  on digest pinning, not on the registry being locked down.

---

## 4. Platform components vs. application onboarding

### What is a platform component

Anything in `iaac-talos-flux-platform`, delivered by **Flux**, shared by every application:

Istio (ambient mesh + the shared Gateway) · cert-manager and the ACME issuers ·
External Secrets Operator and the `ClusterSecretStore` · Kyverno policies · external-dns ·
Velero · the ECR credential sync · **Argo CD itself** · the `app-<name>` namespaces ·
the `apps` AppProject · the ApplicationSet

You do not change any of these. If half the cluster is broken, it is ours.

### What is an application

Anything in your own repo, delivered by **Argo CD** into `app-<name>`:

your Deployment or Job · Services · ConfigMaps · your `ExternalSecret` *references* ·
`deploy/base` and `deploy/overlays/{qa,prod}`

**The boundary is enforced, not advised:**

1. Images must come from `064859874041.dkr.ecr.us-east-2.amazonaws.com` — Kyverno refuses
   Docker Hub and upstream registries.
2. Images must be **pinned by digest**. `:latest` and `:v1.2.3` are both refused. A tag can
   be moved; a digest cannot, and the whole promotion guarantee rests on that.
3. You cannot deploy outside `app-*` — the `apps` AppProject refuses other destinations.
4. You cannot create a namespace — every Application sets `CreateNamespace=false`.

### Troubleshooting boundary

* Your application → **Argo CD**. `argocd app get <name>`, or the UI.
* The platform → **Flux**. `flux get kustomizations`. Ask us.

---

## 5. Onboarding an application — the actual process

### What you send. One message, four facts.

1. **Application name** → becomes namespace `app-<name>`
2. **GitHub repo and branch** to trust for pushing (e.g. `variant-inc/foo` on `master`)
3. **Shape** — service (Deployment + Service) or job (one-shot / scheduled)
4. **Dependencies** — which in-cluster services, which secrets, whether it needs an external route

### What platform does. Six changes, about an hour.

| # | Where | Change |
|---|---|---|
| 1 | ECR account IaC | repository + GitHub OIDC push role |
| 1b | ECR account IaC | **repository policy allowing the cluster accounts to PULL** |
| 2 | `iaac-talos-flux-platform`, each branch | `infrastructure/app-namespaces/app-<name>.yaml` |
| 3 | `iaac-talos-flux-platform`, each branch | ApplicationSet entry — four lines |
| 4 | AWS Secrets Manager | per-environment secret paths |
| 5 | `iaac-talos-flux-platform`, each branch | Argo CD repo credential — one-time per cluster, not per app |
| 6 | — | we hand back the ECR URI and the push role ARN |

Step 5 is done on **QA only**. **Prod has no Git credential and no ApplicationSet**
(INFRA-1650), so nothing can deploy to prod yet regardless of anything you do.

### What you do

1. Copy `app-template/job/` or `app-template/service/`.
2. Set `ECR_REPOSITORY` and `PUSH_ROLE` in `.github/workflows/build-and-push.yml`.
3. Push. The workflow builds, pushes **by digest**, and opens a PR bumping the QA overlay.
4. Merge it; watch the sync in Argo CD.
5. For prod, open a PR moving **the same digest** into `deploy/overlays/prod/`, merge, then
   press Sync. Two gates, both recorded.

---

## 6. The rule that trips everyone: nothing environment-specific in the image

If a value differs between QA and prod, it does not belong in the image — not in a config
file, not in a baked-in default, not in the SQL.

| Value | Where it goes |
|---|---|
| Hostnames, ports, queue and topic names | ConfigMap in `deploy/overlays/<env>/` |
| Credentials, connection strings, API keys | Secrets Manager → `ExternalSecret` → Secret |
| Log level, feature flags, environment name | ConfigMap in the overlay |

An inlined `dev-` topic prefix will not fail loudly in QA. **It will succeed against the
wrong thing.**

---

## 7. Argo CD access

SSO is live on all three clusters as of today, via Entra ID.

* https://argocd.op-dev.usxpress.io
* https://argocd.op-qa.usxpress.io
* https://argocd.op-prod.usxpress.io

You hold the **`app-viewer`** role: read your project's Applications and their logs, sync on
dev and QA, **no sync on prod** — prod promotion is human-initiated by the platform, by
design.

CLI works too:

```bash
argocd login argocd.op-qa.usxpress.io --sso --grpc-web --sso-launch-browser=false
argocd app list
argocd app logs <app>
```

`--grpc-web` is required — TLS terminates at the Istio gateway, so plain gRPC does not
reach the server. `--sso-launch-browser=false` is for WSL, which has no `xdg-open`.

**Only QA currently has an Application to look at** (`risingwave-etl`). dev and prod have
no ApplicationSet yet, so their Applications screen is empty for everyone — that is not a
permissions problem.

---

## 8. Things that are true and surprising

* **A green sync is not a working deploy.** Argo CD reports that Kubernetes accepted your
  manifests and pods became ready. It cannot tell you the work happened. A Job that swallows
  an error and exits 0 looks perfectly healthy. Emit a signal that measures the *outcome*.
* **A green ExternalSecret is not a valid value.** `SecretSynced` proves the sync ran. It has
  twice been green over a value that did not work.
* **`secretKeyRef` env resolves at pod creation.** A rotated secret does not reach a running
  pod, and a container restart replays the *old* value — for months. Recreate the pod.
* **The QA Postgres password drifted for 9 days** this way: initdb on 08-11, secret rotated
  08-12, the database never learned it.
* **"Proven end to end" on 2026-08-20 described one execution.** An hour later the QA path
  was dead for 18 hours — a PR reverted the ApplicationSet's Git URL from `ssh://` to
  `https://`, and GitHub answers *"Repository not found"* for a private repo, which reads
  like deletion rather than auth. Every status field was green.

---

## 9. Where to start

**You are the first application team to use this path**, and the onboarding document has
never been used by anyone. If it does not work for you, it does not work.

Highest leverage, in order:

1. **Containerise the RisingWave workload.** This is the piece the platform genuinely cannot
   supply, and everything downstream waits on it.
2. **`deploy/` base + overlays**, with nothing environment-specific in the image.
3. **Sign in to Argo CD on QA** and confirm you can see `risingwave-etl`, its resource tree
   and the sync-hook Job's logs — and nothing outside `apps`. That is the acceptance test for
   the SSO work.
4. **Tell us what the onboarding doc gets wrong.** That feedback is worth more than the
   deploy.

Open questions that need your answer, not ours: whether QA sync should be yours or ours;
the 238 SIGSEGV restarts on `risingwave-meta-default-0`; and whether RisingWave goes to
prod at all.
