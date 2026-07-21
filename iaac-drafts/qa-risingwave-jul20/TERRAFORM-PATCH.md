# iaac-risingwave-onprem/terraform — make IRSA work on Talos

**Problem:** the IRSA block resolves the OIDC provider through `data "aws_eks_cluster"`.
`op-usxpress-qa` (and `op-usxpress-dev`) are **on-prem Talos** clusters — no EKS cluster
of that name exists, so the lookup fails and nothing can apply.

**Evidence this Terraform has never been applied:** it would create a role named
`risingwave-irsa`, but dev's live role is `op-usxpress-dev-risingwave`. The names don't
match — dev's role was hand-provisioned outside Terraform.

**Good news:** `variables.tf` already declares `oidc_issuer`, `namespace`, and
`service_account`. They're simply unused. The fix wires them in.

---

## Patch — `terraform/main.tf`

### 1. Drop the EKS lookup (lines ~59-65)

```diff
-data "aws_eks_cluster" "cluster" {
-  name = var.cluster_name
-}
-
 data "aws_iam_openid_connect_provider" "cluster" {
-  url = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
+  # On-prem Talos: the OIDC provider is the CloudFront-fronted JWKS endpoint
+  # created by iaac-talos' IRSA module. Looked up, never created here.
+  url = "https://${var.oidc_issuer}"
 }
```

### 2. Use the variables in the trust policy (lines ~67-89)

```diff
     condition {
       test     = "StringEquals"
       variable = "${replace(data.aws_iam_openid_connect_provider.cluster.url, "https://", "")}:sub"
-      values   = ["system:serviceaccount:risingwave:risingwave"]
+      values   = ["system:serviceaccount:${var.namespace}:${var.service_account}"]
     }
```
Defaults are already `risingwave` / `risingwave`, so behaviour is unchanged — but it stops
being a hardcode, and RW-2 or another env can't silently inherit the wrong subject.

### 3. Make the role name per-cluster (line ~91)

```diff
 resource "aws_iam_role" "risingwave_irsa" {
-  name               = "risingwave-irsa"
+  name               = "${var.cluster_name}-risingwave"
   assume_role_policy = data.aws_iam_policy_document.risingwave_assume_role.json
 }
```
Gives `op-usxpress-qa-risingwave`, matching dev's live `op-usxpress-dev-risingwave` and
the ARN in the manifests. Safe to change: no state exists, since this was never applied.

---

## `terraform/op-usxpress-qa.tfvars`

```hcl
cluster_name     = "op-usxpress-qa"
region           = "us-east-2"
aws_profile      = "usx-qa"
oidc_issuer      = "d2t7d36wmf0hbm.cloudfront.net"
namespace        = "risingwave"
service_account  = "risingwave"
s3_bucket_prefix = "risingwave-state"     # confirm against the bucket resource in main.tf
```

Produces: role `op-usxpress-qa-risingwave`, trust
`system:serviceaccount:risingwave:risingwave` against
`d2t7d36wmf0hbm.cloudfront.net`, bucket `risingwave-state-op-usxpress-qa`.

**Clean create — no `terraform import`.** Nothing pre-exists on QA (verified: the only RW
role there is `op-usxpress-qa-risingwave-2`, which belongs to RW-2 and must not be touched).

---

## Apply path

**Octopus, not GitHub Actions and not local.** `.github/workflows/octo.yaml` validates
(`terraform` + `tflint`) on push to any branch, then pushes to Octopus — project
`iaac-risingwave-onprem`, space `DevOps`, scripts in `deploy/`. So `deploy/deploy.sh` is
the Octopus entrypoint, not a manual script. Matches the "Octopus only" standard.

## Follow-up for dev (separate change)

Once this applies cleanly on QA, dev's hand-made `op-usxpress-dev-risingwave` should be
imported so dev stops being un-codified:
```bash
terraform import -var-file=op-usxpress-dev.tfvars aws_iam_role.risingwave_irsa op-usxpress-dev-risingwave
terraform plan -var-file=op-usxpress-dev.tfvars   # must show no changes
```
Don't do this as part of the QA work — land QA first, then backfill dev.
