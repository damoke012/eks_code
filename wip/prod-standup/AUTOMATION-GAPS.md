# Zero-touch prod stand-up — what stands between here and a hands-off run

**Goal (INFRA-1589):** trigger the deploy, walk away, come back to a cluster with Flux
reconciling and the full platform functional — ESO, Grafana, Velero, etcd snapshots,
external-DNS, Argo CD. No kubectl, no console, no "then run this by hand".

Today's plan-only run proves the **infrastructure** layer is ready: `45 to add, 0 to
change, 0 to destroy`, 3 CPs + 10 pool workers, prod state bucket, prod vLAN. Everything
below is about the **platform** layer on top.

---

## G1 — Flux never bootstraps (blocks everything downstream)

`modules/flux` is a TCP wait-loop plus two `removed` blocks. Nothing installs Flux, so no
Kustomization ever reconciles and no platform component exists. See
[PHASE1-FLUX-BOOTSTRAP-GAP.md](PHASE1-FLUX-BOOTSTRAP-GAP.md).

**Do NOT re-add `flux_bootstrap_git`** — it cannot coexist with the `removed` block for the
same address, and it reintroduces the drift cascade that broke dev 3x in 24h.

**Automate instead with a provisioner that applies the already-committed manifests.** No
flux provider, nothing in TF state that can drift, idempotent on re-apply:

```hcl
resource "terraform_data" "flux_bootstrap" {
  triggers_replace = [var.cluster_endpoint]   # once per cluster lifecycle

  provisioner "local-exec" {
    command = <<-SH
      set -euo pipefail
      echo "$KUBECONFIG_CONTENT" > /tmp/kubeconfig-${var.cluster_name}
      export KUBECONFIG=/tmp/kubeconfig-${var.cluster_name}
      git clone --depth 1 --branch master \
        https://x-access-token:$${GITHUB_TOKEN}@github.com/variant-inc/iaac-talos-flux-cluster /tmp/fluxrepo
      kubectl apply -k /tmp/fluxrepo/clusters/${var.cluster_name}/flux-system/
      kubectl -n flux-system wait --for=condition=Available deploy --all --timeout=5m
    SH
  }
  depends_on = [module.talos]
}
```

Effort: small. Lives in `iaac-talos`, benefits dev/QA rebuilds equally.

---

## G2 — Terraform needs credentials in 937464026810 (blocks G3)

With `enable_irsa=true`, Terraform creates S3 + CloudFront + IAM in the **prod** account.
The Octopus worker currently authenticates to the cloud **dev** account
(`700736442855:octopus-usxpress`, per the dev build runbook). `TF_VAR_irsa_role_arn` is
empty in every environment (`qa.tfvars:85`), so nothing assumes into prod today.

`.github/workflows/onprem-account-bootstrap.yaml` already exists for this:
> *"Attaches iaac-talos-bootstrap inline policy to octopus-usxpress. Requires ... with
> `iam:PutRolePolicy` on octopus-usxpress. Store ARN as `ONPREM_BOOTSTRAP_ROLE_ARN_<ENV>`."*

**So this is likely runnable by us, not a cloud project.** Verify, then run it for prod.

**This is the one place a genuine external ask may remain** — and it shrinks to "grant
`iam:PutRolePolicy` on `octopus-usxpress` in 937464026810", not "build us an OIDC stack".
[CLOUD-IRSA-ASK.md](CLOUD-IRSA-ASK.md) **overstates the ask** — items 1-3 (bucket,
CloudFront, OIDC provider) are created by `modules/irsa`. Rewrite before sending.

---

## G3 — Flip `enable_irsa=true` (unlocks every AWS-touching component)

`modules/irsa` builds `aws_s3_bucket.oidc`, the CloudFront distribution,
`aws_iam_openid_connect_provider`, and per-workload roles (external-secrets, external-dns,
velero, etcd-backup, cert-manager, ecr-credentials, octopus-worker). Set
`TF_VAR_enable_irsa=true` and `TF_VAR_irsa_oidc_bucket_name=op-usxpress-prod-irsa-oidc-v2`.

⚠️ Once true, **never** flip back — `false` with IRSA resources in state means DESTROY.

Also re-enables the four `aws_ssm_parameter` resources, so the post-apply SSM validation
becomes live again. Confirm the worker can *read* SSM in whichever account they land in,
or that block `exit 1`s a healthy cluster for a second reason.

---

## G4 — SM secret wrappers must pre-exist ⚠️ NEEDS VERIFICATION

`talosconfig-secret-import.tf` uses `import { for_each = var.enable_irsa ? {...} : {} }`.
A Terraform `import` block against a secret that does not exist **fails the plan**.
Greenfield prod has none of:

```
op-usxpress-prod/talosconfig
op-usxpress-prod/platform/grafana
op-usxpress-prod/platform/grafana/azure-ad
```

If import is unconditional on `enable_irsa`, the first IRSA-enabled apply fails until the
three secrets exist. Automating means either creating them in a pre-step or making the
import conditional on their existence.

**Verify before planning any of this:**
```bash
git show refactor/multi-env-parameterization:deploy/terraform/talosconfig-secret-import.tf
git show refactor/multi-env-parameterization:deploy/terraform/modules/irsa/grafana-secret.tf
git show refactor/multi-env-parameterization:deploy/terraform/modules/irsa/talosconfig-secret.tf
aws secretsmanager list-secrets --profile ops-controller --region us-east-2 \
  --query "SecretList[?starts_with(Name,'op-usxpress-prod')].Name"
```

---

## G5 — `op-prod` branch still points at QA (silent misconfiguration)

12 phase-2 files carry `op-usxpress-qa` / `op-usxpress-dev` literals, inherited when
`op-prod` was cut as an exact copy. Only `cert-manager/release.yaml` was fixed. If phase-2
activates unfixed: ESO reads **QA's** Secrets Manager paths, velero writes **QA's** bucket,
etcd snapshots land in **QA's** bucket, external-dns claims DNS ownership as QA.

Every one of those reconciles **green**. Use `fix-op-prod-literals.sh` (AUTO class only;
ECR registry `064859874041` is central and must not be rewritten).

---

## G6 — `infra.yaml` phase-2 appendix is commented out

`clusters/op-usxpress-prod/flux-system/infra.yaml` ships phase-1 core active and everything
AWS-dependent commented out. ESO, external-dns, velero, etcd-backup, grafana and Argo CD are
**in the commented block**. Uncomment once G2–G5 are done, or none of them deploy at all.

---

## G7 — Acceptance must prove the artifact, not the exit code

Both blockers found on 2026-07-28 passed some form of "it succeeded":

| Gap | How it presented |
|---|---|
| SSM validation | terraform applied fine, deploy went **red** |
| Flux bootstrap | terraform applied fine, deploy went **green**, cluster empty |

The second shape is why B1–B7 exist. Run them all; **B7 first**.

---

## Suggested order

1. **Apply phase 1 now** — it is ready and proves the infra layer. A bare cluster is a
   useful, cheap checkpoint and de-risks everything after it.
2. G1 (flux provisioner) — unblocks all reconciliation, helps dev/QA too
3. G2 (prod account access) — the only possible external dependency; start it in parallel
4. G4 verification → seed secrets if needed
5. G5 + G6 (branch literals, uncomment phase 2)
6. G3 (`enable_irsa=true`) → re-apply
7. B1–B7

**The real acceptance test for INFRA-1589 is a destroy → rebuild cycle with zero manual
steps.** Until that has run once, "automated" is a claim, not a fact — and this whole
stand-up exists because dev and QA were only ever built forward.
