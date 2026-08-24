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

~~**Use `/var/aws-iam-authenticator/kubeconfig.yaml`.**~~ **WRONG — corrected 2026-08-24 20:40.**

**The flag path is `/var/lib/aws-iam-authenticator/kubeconfig.yaml`.** Both log lines are
in-container paths and NEITHER is what the apiserver flag takes. The DaemonSet mounts
`hostPath: /var/lib/aws-iam-authenticator` at `/var/aws-iam-authenticator`, so the server's log
reports where it wrote the file *inside its own container*. The apiserver reads it from the
**host**, via an `extraVolumes` entry mounting `/var/lib/aws-iam-authenticator` at the same path.

`variant-inc/iaac-talos`, branch `feat/aws-iam-authenticator`, says so in the module itself:

```hcl
"authentication-token-webhook-config-file" = "/var/lib/aws-iam-authenticator/kubeconfig.yaml"
# HOST path. The authenticator's own log prints the in-container path; not this one.
```

I wrote the warning above from the server log and got the path wrong in the act of warning about
the path. Three candidate paths appear in this system and only the third is correct:
`/etc/kubernetes/...` (init container, upstream generic, wrong on Talos),
`/var/aws-iam-authenticator/...` (server container, in-container, wrong for the flag),
`/var/lib/aws-iam-authenticator/...` (host, **correct**).

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

1. **Talos machine config** — ⚠️ **the work already exists and is NOT MERGED.**
   `variant-inc/iaac-talos` branch `feat/aws-iam-authenticator` (head `ca5479f`) carries it:
   `apiserver_extra_args` + `apiserver_extra_volumes` in
   `deploy/terraform/modules/talos/main.tf`, gated on `var.enable_aws_iam_authenticator`, plus
   one line in `deploy/terraform/envs/qa.tfvars`. `git branch -r --merged origin/master` does
   not list it.

   **So op-usxpress-QA's working SSO is running on a machine config that is not in master.** A
   redeploy of QA from `master` takes SSO away, silently, because the flag simply would not be
   in the generated config. That is a bigger problem than dev not having it yet.

   The remaining work is to **finish and merge that branch**, adding `enable_aws_iam_authenticator`
   to dev's and prod's tfvars — not to write anything new. Then promote through **Octopus only**
   (CLAUDE.md rule 1), dev first.

   Note the module comment on why the apiServer patch is assembled from one merged map: two
   patches both setting `extraArgs` would depend on Talos merging rather than replacing them,
   and if it replaces, **IRSA silently breaks**.
2. **Prove the login**: `aws sso login --profile usx-dev` then `kubectl auth whoami`, expecting
   `sso:<email>` in group `onprem-platform-admins`. A wrong ARN does **not** error — the caller
   becomes `system:anonymous` and everything returns `forbidden`, which reads like an RBAC bug.
3. **Keep the x509 admin kubeconfig open** as break-glass throughout.
4. **prod manifests**: ✅ raised — platform PR **#125**, cluster PR **#37**, both OPEN and
   verified (8 files + 1; account `937464026810`, suffix `837df2a43495aaf1`, cluster-id
   `op-usxpress-prod` in both the init arg and `--cluster-id`). Merge #125 first.

   ⚠️ **prod's apiserver flag has no known home.** `op-usxpress-prod` appears NOWHERE in
   `variant-inc/iaac-talos` — not in `deploy/terraform/envs/` (only `dev.tfvars` and
   `qa.tfvars` exist), not in any `.tf`, and `git log --all -S 'op-usxpress-prod' -- deploy/`
   returns nothing on any branch. Prod was stood up in INFRA-1589/1621 and its platform stack
   fully reconciled 2026-07-29, so something generated its machine config.

   **Most likely** — and this is a HYPOTHESIS, not a finding — prod's variables are supplied by
   Octopus rather than by a repo tfvars file, which would match [[onprem-deploy-via-octopus]]
   and [[octopus-green-but-no-apply]] (`TfApply=false` everywhere but production). **Verify in
   Octopus before acting on it.** Do not add a `prod.tfvars` on the assumption that the pattern
   matches dev and QA.

   Confirm `scripts/breakglass-prod-kubeconfig.sh` produces a working kubeconfig *before* the
   flag lands on prod. The `usx-prod` profile has a live SSO session as of 2026-08-24, so this
   is checkable now.
5. **QA reconciliation, later**: QA maps `op-qa-platform-admin`, dev and prod map
   `usx-on-prem-admins`. Add the latter to QA's `aws-auth` as an **additional** entry — never
   replace the only working path into a cluster.

---

**Proven:** the authenticator runs on all three op-dev control planes with the correct ARN and
binding, and writes its webhook kubeconfig to `/var/aws-iam-authenticator/kubeconfig.yaml`.
**Tested and killed:** "QA's SSO was hand-applied so this is not GitOps" — wrong, QA is wired in
`iaac-talos-flux-cluster` at `clusters/op-usxpress-qa/flux-system/infra.yaml:751`; the grep that
suggested otherwise was run against the wrong repository.
**Not answered:** where prod's Talos machine config lives — it is not in `iaac-talos` on any
branch. Until that is known, prod's apiserver flag cannot be written, only guessed at.
**Traps:** THREE different paths appear and only the host one is right for the flag —
`/etc/kubernetes/...` (init, generic), `/var/aws-iam-authenticator/...` (server, in-container),
`/var/lib/aws-iam-authenticator/...` (host, correct); QA's apiserver flag lives on an UNMERGED
`iaac-talos` branch, so redeploying QA from master would remove its SSO; the IMDS region warning is benign; merging the wiring before the manifests leaves a
Kustomization `Ready=False` with `path not found` until the `infra` source fetches (5m interval);
a wrong ARN produces `forbidden`, never an error.
