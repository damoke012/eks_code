---
name: onprem-prod-sso-is-half-landed
description: "MEASURED 2026-10-20: op-usxpress-prod already runs the aws-iam-authenticator DaemonSet 3/3, with aws-auth mappings and all three ClusterRoleBindings — but the kube-apiserver webhook flag is OFF. The Git half was copied to prod; the Terraform half never was"
metadata:
  type: project
---

**Measured on both clusters, 2026-10-20.** The prod AWS SSO work is **further along than any
note said**, and the split is exactly along the repository boundary.

| Piece | Where it lives | op-qa | op-prod |
|---|---|---|---|
| `aws-iam-authenticator` DaemonSet | Flux, platform repo | ✅ 3/3 ready | ✅ **3/3 ready** |
| `aws-auth` ConfigMap | Flux, platform repo | ✅ (admin tier only) | ✅ **(admin tier only)** |
| Three ClusterRoleBindings | Flux, platform repo | ✅ | ✅ |
| **kube-apiserver webhook flag** | **Terraform, via Octopus** | ✅ present | ⛔ **absent** |

**The pattern:** everything in the **platform Git repository** was copied to the `op-prod`
branch and reconciled. The one piece that lives in **Terraform and deploys through Octopus**
was applied to QA only — it is enabled per environment by an Octopus variable, and that
variable was never scoped to production.

**Two consequences that change how the work is sized.**

1. **The dangerous ordering problem is already satisfied.** The documented hazard is that
   `kube-apiserver` will not start if the webhook config file is missing, and the DaemonSet is
   what writes it. That DaemonSet has been running 3/3 on prod for some time, so the
   prerequisite is in place rather than being something to stage. **Still verify the file on
   each control-plane node** — a Ready pod is not a written file
   ([[adjacent-step-green-signals]]) — but the risk is much lower than planned for.
2. **The prod admin role already exists.** `AWSReservedSSO_usx-on-prem-admins_837df2a43495aaf1`
   carries a real suffix, which cannot be invented — so the permission set was created. What
   is unknown is who is assigned to it.

⚠️ **Do not read "the DaemonSet exists" as "SSO works".** It proves three of the seven pieces.
The flag is the one that makes the API server consult it at all, and it is off.

⚠️ Two of the three access tiers are broken on **both** clusters —
[[onprem-sso-placeholders-break-two-tiers]].

Related: [[onprem-human-access-model]], [[manifests-copied-across-branches]] (the same
copy-the-branch pattern, this time working in our favour), [[octopus-green-but-no-apply]].

## ✅ 2026-10-27 — the apiserver half LANDED. INFRA-1661's mechanism is done.

Release `0.5.0` deployed to Production via Octopus, 21 minutes, no incident. Measured on the
cluster afterwards, not inferred from the deploy's own report:

```
--authentication-token-webhook-config-file=/var/lib/aws-iam-authenticator/kubeconfig.yaml
--authentication-token-webhook-cache-ttl=2m0s
```

present on all three control planes. 13/13 nodes Ready. `kube-apiserver-talos-cp-op-prod-1..3`
all Ready with 0 restarts. The `[HEALTH] Waiting for istiod` step burned its full 1200s and
continued — the known defect ([[istiod-health-wait-cannot-fail]]), not a fault.

**What made it safe:** the webhook kubeconfig was proven present on every control-plane node
*before* the flag landed, because kube-apiserver does not start without that file. Proof via
the Talos API, with QA as a positive control:
`scripts/check-authenticator-webhook-file.sh qa && ... prod`.

**Still open, and it is NOT a cluster problem:** no human can log in yet. The permission set is
granted to a group the platform team is not in — see [[sso-grant-is-group-membership]]. The
cluster will accept an SSO login the moment that grant exists.

⚠️ **Corrects the line above about `op-prod` being a near-powerless platform-admin profile.**
Measured: `aws configure get sso_role_name --profile op-prod` returns **`usx-on-prem-admins`**,
exactly the role prod's aws-auth maps. It was never a permissions gap in the profile; nobody
had logged into it, and `sts get-caller-identity` failing was read as "wrong role" when the
honest reading was "no session".
