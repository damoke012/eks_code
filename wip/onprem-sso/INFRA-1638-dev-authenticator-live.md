# INFRA-1638 — aws-iam-authenticator live on op-usxpress-dev (manifests half)

**2026-08-24 20:04 UTC.** Both halves merged and reconciled on **op-usxpress-dev only**.
QA has had this since 2026-07-28; **prod is not done**.

- `variant-inc/iaac-talos-flux-platform` PR #124 → branch `op-dev`, 8 files
  (`infrastructure/rbac/` + `infrastructure/aws-iam-authenticator/`)
- `variant-inc/iaac-talos-flux-cluster` PR #36 → `clusters/bm-dev/flux-system/infra.yaml`,
  two Kustomizations (`rbac`, then `aws-iam-authenticator` with `dependsOn: rbac`)

---

## ⚠️ The apiserver flag path — the two log lines disagree

The **init** container prints upstream's generic advice:

```
copy aws-iam-authenticator.kubeconfig to /etc/kubernetes/aws-iam-authenticator/kubeconfig.yaml
configure your apiserver with `--authentication-token-webhook-config-file=/etc/kubernetes/aws-iam-authenticator/kubeconfig.yaml`
```

The **server** container prints where the file actually is:

```
writing webhook kubeconfig file  kubeconfigPath=/var/aws-iam-authenticator/kubeconfig.yaml
```

**Use `/var/aws-iam-authenticator/kubeconfig.yaml`.** On Talos `/etc/kubernetes` is managed by
the OS and is not writable by us; the DaemonSet mounts `hostPath: /var/lib/aws-iam-authenticator`
at `/var/aws-iam-authenticator`. Taking the init container's path gives the apiserver a file
that does not exist, and an apiserver that will not start on Talos is not a quick fix.

The DaemonSet comment already says *"Deploy this BEFORE the apiserver flag… if the flag lands
first, apiserver will not start."* Both halves of that warning matter: order **and** path.

## Benign: the IMDS line

```
failed to get region from IMDS for handler configuration, defaulting to us-east-1
```

There is no IMDS on bare metal. The `EKSConfigMap` backend does not call the AWS API to resolve
a mapping, so this does not affect authentication; QA has run with the same line since
2026-07-28. Do not chase it.

## What is proven, and what is not

**Proven on op-dev 2026-08-24 20:04 UTC:**

- 3/3 DaemonSet pods `Running`, `RESTARTS 0`, one per control-plane node
  (`talos-cp-op-dev-1/2/3` at 10.10.82.29 / .181 / .179). The liveness probe carries
  `host: 127.0.0.1`, without which it probes the node IP and CrashLoops (~140 restarts/8h).
- `kube-system/aws-auth` carries
  `arn:aws:iam::700736442855:role/AWSReservedSSO_usx-on-prem-admins_b7447c115978d407`,
  **path stripped**.
- `clusterrolebinding/onprem-platform-admins` → group `onprem-platform-admins` → `cluster-admin`.
- Each server logged `starting mapper "EKSConfigMap"`, `Received aws-auth watch event`, and
  `listening on 127.0.0.1:21362`.

**NOT proven, and this ticket does not close until it is:** that anyone can log in. The
apiserver has no `--authentication-token-webhook-config-file` yet, so nothing consults any of
this. It is inert and correct-looking, which is the exact combination worth distrusting.

## Remaining, in order

1. **Talos machine config** — the apiserver flag, in `iaac-talos`, promoted through **Octopus
   only** (CLAUDE.md rule 1). Path above. Dev first.
2. **Prove the login**: `aws sso login --profile usx-dev` then `kubectl auth whoami`, expecting
   `sso:<email>` in group `onprem-platform-admins`. A wrong ARN does **not** error — the caller
   becomes `system:anonymous` and everything returns `forbidden`, which reads like an RBAC bug.
3. **Keep the x509 admin kubeconfig open** as break-glass throughout.
4. **prod**: `scripts/pr-sso-dev-prod.sh --only op-prod`. Confirm
   `scripts/breakglass-prod-kubeconfig.sh` produces a working kubeconfig *before* the flag lands.
5. **QA reconciliation, later**: QA maps `op-qa-platform-admin`, dev and prod map
   `usx-on-prem-admins`. Add the latter to QA's `aws-auth` as an **additional** entry — never
   replace the only working path into a cluster.

---

**Proven:** the authenticator runs on all three op-dev control planes with the correct ARN and
binding, and writes its webhook kubeconfig to `/var/aws-iam-authenticator/kubeconfig.yaml`.
**Tested and killed:** "QA's SSO was hand-applied so this is not GitOps" — wrong, QA is wired in
`iaac-talos-flux-cluster` at `clusters/op-usxpress-qa/flux-system/infra.yaml:751`; the grep that
suggested otherwise was run against the wrong repository.
**Traps:** the init and server containers print different paths and the init's is wrong for
Talos; the IMDS region warning is benign; merging the wiring before the manifests leaves a
Kustomization `Ready=False` with `path not found` until the `infra` source fetches (5m interval);
a wrong ARN produces `forbidden`, never an error.
