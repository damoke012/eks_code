# App template — on-prem delivery

Two shapes. Pick one and copy it into your repo.

| | Use when | Deploys |
|---|---|---|
| [`job/`](job/) | one-shot or scheduled work: apply SQL, run a migration, batch job | a `Job` as an Argo CD Sync hook, so it re-runs on every sync and its logs land in the Argo UI |
| [`service/`](service/) | long-running HTTP or gRPC workload | a `Deployment` + `Service` |

Both share the same contract, and it's the contract that matters more than the files:

1. **The image is built in CI on a GitHub-hosted runner** and pushed to the shared ECR **by digest**.
   Nothing builds on the on-prem clusters.
2. **The image contains nothing environment-specific.** No hostnames, no topic names, no
   credentials. If a value differs between QA and prod, it does not belong in the image.
3. **Overlays pin the digest.** `deploy/overlays/<env>/kustomization.yaml` carries
   `digest: sha256:…`, and promotion is a pull request that changes that one line.
4. **Config comes from the cluster.** Coordinates from a ConfigMap in the overlay; secrets from AWS
   Secrets Manager via External Secrets. The platform delivers both.
5. **The same digest goes to prod.** Nothing is rebuilt between environments. What runs in prod is
   the artefact that passed in QA.

Kyverno enforces 1 and 3 at admission: images must come from the approved registry and must be
pinned by digest. A `:latest` reference is rejected.

## Onboarding checklist

- [ ] Copy `job/` or `service/` into your repo
- [ ] Set `ECR_REPOSITORY` and the role ARN in `.github/workflows/build-and-push.yml`
- [ ] Ask platform for: an `app-<name>` namespace, an ECR repository, and a push role
- [ ] Ask platform to add four lines to the QA `ApplicationSet`
- [ ] Push to `main` — the workflow builds, pushes, and opens the QA promotion PR
- [ ] Merge it; watch the sync in Argo CD
- [ ] For prod: a second PR against the prod overlay with the **same** digest
