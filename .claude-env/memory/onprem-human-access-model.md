---
name: onprem-human-access-model
description: "How humans get kubectl on the on-prem Talos clusters — AWS SSO via self-hosted aws-iam-authenticator. LIVE on op-usxpress-qa 2026-07-28; dev AND prod have the authenticator but not the apiserver flag (2026-08-24, INFRA-1661)."
metadata: 
  node_type: memory
  type: project
  originSessionId: e3125f37-c991-4364-adf2-b40770a2d61c
  modified: 2026-08-24T20:15:00.000Z
---

**✅ LIVE on `op-usxpress-qa` 2026-07-28.** `kubectl auth whoami` → `sso:doke@usxpress.com`, groups
`[onprem-platform-admins]`, no cert. Granting = assign an AWS SSO permission set, exactly like
[[eks-human-access-model]]. **Idris onboarded end-to-end 2026-08-03** — `sso:ifagbemi@usxpress.com`,
`onprem-platform-admins`, 13 nodes. First non-author to use the path, so the model is proven. Dev + prod
still to do.

⚠️ **2026-08-24 — op-usxpress-dev now has the AUTHENTICATOR half** (INFRA-1638). Manifests:
`iaac-talos-flux-platform` PR #124 on `op-dev` (`infrastructure/rbac` +
`infrastructure/aws-iam-authenticator`). Wiring: `iaac-talos-flux-cluster` PR #36
(`clusters/bm-dev/flux-system/infra.yaml`). 3/3 pods on the CPs, 0 restarts, correct ARN, mapper
loaded. **Nobody can log in yet** — the apiserver `--authentication-token-webhook-config-file`
flag is Talos machine config in `iaac-talos`, promoted through Octopus, and still to do. Prod
**op-usxpress-prod has it too as of 2026-08-24 20:20** (PRs #125/#37) — both Kustomizations
`Ready=True` on `op-prod@sha1:6f7e9daf`, 3/3 pods, 0 restarts, prod's own ARN
(`937464026810` / `837df2a43495aaf1`). Verified through
`scripts/breakglass-prod-kubeconfig.sh`, which was exercised for real and works — one of
INFRA-1661's preconditions proven rather than assumed. **Neither dev nor prod can log in yet**;
the apiserver flag is INFRA-1661.

⚠️ **THREE paths, only one right.** The apiserver flag takes the **HOST** path
`/var/lib/aws-iam-authenticator/kubeconfig.yaml`. The init container's log says
`/etc/kubernetes/...` (upstream generic, wrong on Talos — OS-managed). The server container's
log says `/var/aws-iam-authenticator/...` (where it wrote the file INSIDE its container). Neither
is the flag. Confirmed in `iaac-talos` `feat/aws-iam-authenticator`:
`"authentication-token-webhook-config-file" = "/var/lib/aws-iam-authenticator/kubeconfig.yaml"`
with `# HOST path. The authenticator's own log prints the in-container path; not this one.`
An apiserver pointed at a missing file will not start.

⚠️ **QA's apiserver flag is on an UNMERGED branch.** `variant-inc/iaac-talos`
`feat/aws-iam-authenticator` (head `ca5479f`) holds the whole Talos half —
`apiserver_extra_args` + `apiserver_extra_volumes` in
`deploy/terraform/modules/talos/main.tf` gated on `var.enable_aws_iam_authenticator`, plus a
line in `deploy/terraform/envs/qa.tfvars`. It is NOT merged to master.
**Redeploying op-usxpress-qa from master would remove its SSO, silently.** Finishing INFRA-1638
means merging that branch and adding the flag to dev's and prod's tfvars — not writing anything
new. The module deliberately assembles ONE apiServer patch from a merged map: two patches both
setting extraArgs would rely on Talos merging rather than replacing, and if it replaces, IRSA
silently breaks.

⚠️ **One permission set, three different ARNs.** `usx-on-prem-admins` is provisioned to all
three accounts and AWS generates a DIFFERENT suffix in each: dev `b7447c115978d407`, qa
`8c7f139e431625e0`, prod `837df2a43495aaf1`. Read it back with `aws iam list-roles`; never copy
between clusters; strip the `aws-reserved/sso.amazonaws.com/` path. A wrong ARN does not error —
the caller becomes `system:anonymous` and everything returns `forbidden`, which reads like an
RBAC bug. QA maps `op-qa-platform-admin` instead: leave it alone and add `usx-on-prem-admins`
there as an ADDITIONAL entry, never replace the only working path into a cluster.
See `wip/onprem-sso/INFRA-1638-dev-authenticator-live.md` and [[adjacent-step-green-signals]].

~~**Confirmed 2026-08-18: prod has NO SSO path.**~~ **Superseded 2026-08-24 — prod now has the
authenticator and RBAC (see above); it still has no LOGIN until INFRA-1661.** The rest of this
paragraph was accurate when written: `infrastructure/aws-iam-authenticator` exists only on the
`op-qa` branch and is wired only in `clusters/op-usxpress-qa`. `op-prod` has neither the directory nor the
Kustomization, so `op-usxpress-prod` (API `10.10.82.52`) has no routine human access — break-glass only, via
`op-usxpress-prod/talosconfig` in Secrets Manager account 937464026810 (`usx-prod` profile) →
`talosctl kubeconfig`. Dev likewise still unwired. This blocks routine verification of prod changes, e.g.
checking prod's Flux Git token ([[onprem-app-cicd]]).

**Client-side delivery is where ALL the time went (2026-08-03), not the cluster.** Budget for it:
- **The client kubeconfig contains no secret** — no key, cert or token; creds are fetched at call time by the
  exec plugin. But **Teams silently dropped the attachment 3×**. What worked: a **single-line** `kubectl
  config set-cluster/set-credentials/set-context` chain with the CA inlined as base64 and `&&` between steps,
  ending in `kubectl auth whoami`. No YAML, no indentation, no heredoc → no chat client can corrupt it.
  Command form is in `wip/onprem-qa-access/aws-sso-webhook/client-kubeconfig-template.yaml` header.
- **Never paste a large heredoc into Doke's WSL** — it mangles mid-block and writes a plausible-looking file.
- **`~` does NOT expand after `--kubeconfig=`.** kubectl then reads a nonexistent path and returns an **empty
  config instead of an error**. Symptoms: `clusters: null`, `current-context must exist in order to minify`,
  a zero-length CA, or `x509: certificate signed by unknown authority`. I misread this as "the file is
  corrupt" and had a good file rebuilt. **Use `$HOME`, and echo `${#CA}` before using it.**
- Send corrections from the repo copy, not from an earlier draft — the sent message said `usx-qa` while the
  repo already said `op-qa`, and Idris was told the wrong profile.

**The mechanism is the one EKS already runs for you:** self-hosted `aws-iam-authenticator` on the Talos
control plane, `EKSConfigMap` backend reading `kube-system/aws-auth` in the exact EKS format. Entra OIDC was
dropped as the cluster-access answer — it needs an app registration and Doke has no Azure access (still right
for app-level SSO, [[rw-platform-sso-entra]]).

Pack + full write-up: `wip/onprem-qa-access/aws-sso-webhook/` (`FINDINGS-2026-07-28.md`).

**How to apply — the traps that cost the most, in order:**
- **`TfApply=false` is scoped `(all)` with `true` only on `production`.** Octopus runs plan, PRINTS the diff,
  skips apply, exits 0 — **task goes green having changed nothing.** Five QA deploys did this. Assume nothing
  landed unless you see `Apply complete!` in the log. Applies to ANY iaac-talos change, not just this work.
- **Octopus reads `TF_VAR_*` (env.auto.tfvars), never `-var-file`** — a value in `envs/qa.tfvars` is ignored
  by real deploys ([[onprem-deploy-via-octopus]]). Use `add-octopus-var.py` in the pack.
- **A release pins a variable SNAPSHOT** — adding a project variable does not reach an existing release;
  needs "Update Variables" or a new release.
- **`aws-auth` maps the ROLE, not the person.** A profile assuming `AWSAdministratorAccess` logs in fine,
  `get-caller-identity` looks fine, cluster says `Unauthorized`. Needs a dedicated `op-qa` profile with
  `sso_role_name = op-qa-platform-admin`. Never map the admin role in aws-auth.
- **kube-apiserver will not start if the webhook config file is missing** → DaemonSet writes it on EVERY CP
  first, verify per node (image is distroless — check `kubectl logs`, not `exec`).
- **The flag needs the FILE, not a reachable server** — x509 auth is unaffected, so the tfstate-derived
  `system:masters` kubeconfig is the way back in ([[wsl-kubeconfig-churn]]).
- **Strip the path from the SSO role ARN** in aws-auth, or callers land as `system:anonymous`.

Group-keyed ClusterRoleBindings (`onprem-platform-admins`→cluster-admin, `-operators`, `-users`) are
Flux-managed on the env branch and are the target of any auth front-end. Per-user X.509 certs are now
**break-glass only** (user generates the key; admin sees only CSR + cert).

VIPs vLAN 82: dev `.50` / qa `.51` / prod `.52`, all `:6443`. AWS accts: dev `700736442855`,
qa `527101283767`, prod `937464026810`. Prod must NOT get a standing admin assignment.
See [[qa-cluster-standup]], [[prod-standup]].
