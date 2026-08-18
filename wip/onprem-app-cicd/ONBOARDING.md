# Deploying an application on-prem

**Audience:** application teams. **Platform contact:** on-prem platform team.

This is the supported path for any application running on the on-prem Talos clusters
(`op-usxpress-dev`, `op-usxpress-qa`, `op-usxpress-prod`). If you are lifting an existing
cloud application across, that goes through DX / MageRunner instead — ask us, don't guess.

## The model in one paragraph

You commit code. GitHub Actions builds an image and pushes it to the shared ECR **by digest**.
A pull request moves that digest into the QA overlay; Argo CD applies it. A second pull request
moves the **same digest** into the prod overlay. Nothing is rebuilt between environments, so what
runs in production is provably the artefact that passed in QA.

```
push to main ──► GitHub Actions ──► ECR (by digest) ──► PR bumps QA overlay
                                                            │
                                              Argo CD (QA) syncs ──► app-<name>
                                                            │
                                        PR bumps prod overlay, same digest
                                                            │
                                            Argo CD (prod), manual sync
```

## What you own, what we own

| | You | Platform |
|---|---|---|
| Application code and Dockerfile | ✅ | |
| The Kubernetes manifests in your repo (`deploy/`) | ✅ | |
| Which digest goes to which environment (the PRs) | ✅ | |
| The `app-<name>` namespace, quota, PodSecurity, Istio | | ✅ |
| ECR repository and push credentials | | ✅ |
| Argo CD, the AppProject, the ApplicationSet entry | | ✅ |
| Secret **delivery** (AWS Secrets Manager → the cluster) | | ✅ |
| Secret **values** | ✅ | |
| DNS, TLS, ingress | | ✅ (via `platform-app-expose`) |

## Rules that are enforced, not advised

Kyverno rejects manifests that break these:

1. **Images come from `064859874041.dkr.ecr.us-east-2.amazonaws.com`.** Build in CI; don't reference
   Docker Hub or upstream registries directly from a Deployment.
2. **Images are pinned by digest**, never by tag. `:latest` and `:v1.2.3` are both refused. A tag can
   be moved; a digest cannot, and the promotion guarantee depends on that.

And two that are structural rather than policy:

3. **You cannot deploy outside your namespace.** The `apps` AppProject only permits destinations
   matching `app-*`. An Application pointing at a platform namespace is refused by Argo CD.
4. **You cannot create a namespace.** Every Application sets `CreateNamespace=false`.

## Nothing environment-specific in the image

This is the one that trips people up. If a value differs between QA and prod it does not belong in
the image — not in a config file, not in a baked-in default, not in the SQL.

| Value | Where it goes |
|---|---|
| Hostnames, ports, queue and topic names | a ConfigMap in `deploy/overlays/<env>/` |
| Credentials, connection strings, API keys | AWS Secrets Manager → `ExternalSecret` → Secret |
| Log level, feature flags, environment name | ConfigMap in the overlay |

If you inline a `dev-` prefixed topic or a broker hostname, the artefact built in dev will point at
dev's dependencies when it runs in QA. It will not fail loudly; it will succeed against the wrong
thing.

## To get started

1. **Copy a template.** `app-template/job/` for one-shot or scheduled work, `app-template/service/`
   for a long-running HTTP workload. The README explains the difference.
2. **Ask platform for four things**, in one message:
   - an `app-<name>` namespace
   - an ECR repository
   - a GitHub OIDC push role (tell us the repo and the branch to trust)
   - an entry in the QA ApplicationSet
3. **Set two values** in `.github/workflows/build-and-push.yml`: `ECR_REPOSITORY` and `PUSH_ROLE`.
4. **Push to `main`.** The workflow builds, pushes, and opens a PR bumping the QA overlay.
5. **Merge it** and watch the sync in Argo CD.
6. **For prod**, open a PR moving the same digest into `deploy/overlays/prod/`. Merge it, then press
   Sync in Argo CD. Two gates, both recorded.

## Where to look when something is wrong

| Symptom | Look at |
|---|---|
| Image won't pull | `kubectl -n app-<name> get secret ecr-pull-secret` — it's refreshed every 5 min by the platform |
| Argo CD says the Application is refused | the destination namespace isn't `app-*`, or the AppProject doesn't allow the repo |
| Admission rejected the pod | Kyverno: almost always a tag instead of a digest, or a non-ECR image |
| Pod won't start, `CreateContainerConfigError` | a ConfigMap or Secret named in `envFrom` doesn't exist yet |
| Sync green but nothing happened | check the Job's logs, not its exit status — see below |

**A green sync is not a working deploy.** Argo CD reports whether Kubernetes accepted your manifests
and the pods became ready. It cannot tell you the work happened. If your Job returns success while
swallowing an error, everything upstream looks healthy. Emit a signal that measures the outcome, not
the request.

## Troubleshooting boundary

Two controllers, two domains, deliberately:

- **Your application** → Argo CD. `argocd app get <name>`, or the UI.
- **The platform** (Istio, cert-manager, External Secrets, the registry credential sync) → Flux.
  `flux get kustomizations`. Not yours to change; ask us.

If your app is broken, start in Argo CD. If half the cluster is broken, it's ours.
