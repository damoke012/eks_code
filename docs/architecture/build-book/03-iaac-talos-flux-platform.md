# Repo 3 — `variant-inc/iaac-talos-flux-platform`

**Repo:** <https://github.com/variant-inc/iaac-talos-flux-platform>
**Read at:** branches `op-qa` and `op-prod`, 2026-09-17.
**Default branch:** `op-dev` — which matters, see §2.

**What it does:** the platform stack. Everything the cluster runs that is not an application
and not the cluster itself. Repo 2 says *where to look*; this is *what is there*.

---

## 1. The 42 components on `op-qa`

```
app-namespaces          cross-cluster-app-secrets  istio-namespace     prometheus
app-secrets             cross-cluster-eso          istiod-health       prometheus-rules
arc-controller          ecr-credentials            keda                rbac
arc-runner-rw-pipeline  etcd-backup                kyverno             reloader
argocd                  external-dns               kyverno-policies    risingwave-routes
argocd-apps             external-secrets           local-path-storage  rook-ceph-cluster
argocd-config           external-secrets-config    octopus-worker      rook-ceph-operator
aws-iam-authenticator   grafana                    pod-identity-webhook rook-recovery-jobs
cert-manager            istio                      trust-manager       trust-manager-bundle
cert-manager-issuers    istio-csr                  velero
cilium-hygiene          istio-ingress
cilium-lb
```

Each becomes one Flux `Kustomization` in repo 2's `infra.yaml`, ordered by `dependsOn`.

---

## 2. Branch per cluster — and two naming schemes

Live branches are **`op-dev`, `op-qa`, `op-prod`**. The repo *also* carries `dev`, `qa`,
`prod` and `stage`, which nothing in repo 2 references. Two schemes for three environments.

**The default branch is `op-dev`.** Because the repo is branch-per-cluster, GitHub's
"Create a pull request" link after a push opens the compare page with **base=op-dev**,
whatever branch the work was built from — so a prod change is one click from merging into dev.
The tells are "Can't automatically merge" and an empty auto-filled title, neither of which
reads as an error. Always:

```bash
gh pr create --base <the branch it was built FROM> --head <topic> --fill
```

Enforced by `scripts/lint-pr-base-pinned.sh` in `eks_code`.

**Drift, `op-qa` vs `op-prod`:** 44 files, 196 insertions against 349 deletions. Prod is
materially smaller — it dropped `cross-cluster-eso` and the QA-only extras.

---

## 3. The ingress and DNS chain — where the silent failures live

Four links, each of which fails without an error when broken.

### Link 1 — the Gateway must exist, by name

```yaml
spec:
  gateways:
    - tcp-passthrough
```

> A VirtualService whose Gateway does not exist reports **no error, no status condition and
> no event**.

That is from the file's own header, and it happened twice: `tcp-passthrough` was selected by
name on both `op-qa` and `op-prod` **before it was defined on either branch**. Both sets of L4
routes bound to nothing, silently, until INFRA-1645 and INFRA-1674 ported it in.

### Link 2 — the host suffix is per cluster

```yaml
  - port: { number: 4567, name: rwsql, protocol: TLS }
    tls: { mode: PASSTHROUGH }
    hosts:
    - "*.op-qa.usxpress.io"        # op-prod: "*.op-prod.usxpress.io"
```

The suffix is the **only** intended difference between the branches' Gateways.

### Link 3 — hostPort, because the Gateway Service is ClusterIP

The ingress Service is ClusterIP; a `postRenderer` in `infrastructure/istio-ingress/release.yaml`
makes the DaemonSet bind **hostPort 4567 and 5432**. That is what makes node addresses answer
at all. The Gateway alone is not sufficient.

### Link 4 — external-dns needs an explicit target

```yaml
  annotations:
    external-dns.alpha.kubernetes.io/hostname: rw-sql.op-prod.usxpress.io
    external-dns.alpha.kubernetes.io/target: "10.10.82.109,10.10.82.190,…"
```

> external-dns v0.20.0 produces **ZERO endpoints** for the istio-virtualservice source when
> the bound Gateway's Service is ClusterIP, unless a per-VS target annotation is present.
> **Required, not optional.**

And the target list is **this cluster's own worker addresses**, different everywhere:

| Cluster | Targets |
|---|---|
| dev | 7 addresses |
| QA | 3 — `10.10.82.23, .106, .139` |
| prod | 10 — `10.10.82.109, .190, .191, .112, .189, .111, .110, .108, .113, .185` |

---

## 4. The copied-identifier class — ten instances and counting

Both `virtualservice-sql.yaml` files record their own history:

> This file arrived on the op-prod branch as a verbatim copy of the dev branch's: it
> advertised the DEV hostname for this service and targeted dev's seven worker addresses.
> Nothing looked wrong in the cluster — **external-dns skips records owned by another
> cluster's txt-owner-id, so a route publishing another environment's hostname produces no
> error, no event and no record.** Tenth instance of the copied-identifier class; op-qa was
> the ninth.

**This is the defining hazard of a branch-per-cluster repo.** A copied file is syntactically
valid, reconciles green, and publishes another environment's identity into the void. Nothing
in Flux, Istio or external-dns objects.

**So: never create a new cluster's branch by copying another and fixing what you notice.**
Copy, then diff every identifier — hostnames, IP lists, account ids, ARNs, bucket names,
`txtOwnerId` — against what that cluster actually owns. See
[[manifests-copied-across-branches]] and [[onprem-ingress-dns-convention]].

---

## 5. What a new cluster needs here

1. **A branch `op-<env>`**, cut from `op-prod` rather than `op-qa` — prod is self-contained,
   fully active, and carries the better documentation.
2. **Every identifier re-derived**, not inherited: host suffix `*.op-<env>.usxpress.io`,
   external-dns targets = *this* cluster's worker addresses, AWS account id, ARNs, bucket
   names, `txtOwnerId`.
3. The branch must exist **before** Flux bootstrap, or repo 2's `infra` GitRepository cannot
   resolve.

---

## Proven

- 42 infrastructure components on `op-qa`; branches `op-dev`/`op-qa`/`op-prod` are the live
  ones; `dev`/`qa`/`prod`/`stage` are referenced by nothing in repo 2. Read 2026-09-17.
- QA↔prod drift is 44 files; prod is smaller, having dropped `cross-cluster-eso`.
- The L4 ingress chain has four independent links, each failing silently: Gateway existence,
  host suffix, hostPort via postRenderer, and the external-dns target annotation.
- QA publishes 3 worker addresses, prod 10, dev 7 — per cluster, never shared.

## Tested and killed

- *"Branch per cluster means a new environment is a branch copy."* It is the copy that causes
  the failures. Ten recorded instances of a verbatim copy carrying another environment's
  identity, reconciling green and serving nothing.

## Traps

- **The default branch is `op-dev`**, so an un-pinned `gh pr create` offers to merge a prod
  change into dev.
- **A VirtualService bound to a missing Gateway is silent** — no error, no condition, no event.
- **external-dns ignores records owned by another cluster's `txtOwnerId`** — a wrong hostname
  produces no record and no complaint.
- **Two naming schemes for the same three environments**; only `op-*` is wired.
- **QA-2 must be bootstrapped on Flux v2.7.5** to match QA and prod, not the newest CLI
  default — see [[flux-version-drift-dev-ahead]].
