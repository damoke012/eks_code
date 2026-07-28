# iaac-talos — enable the authenticator webhook on kube-apiserver

Target: `deploy/terraform/modules/talos/main.tf`, the `data "talos_machine_configuration" "controlplane"`
block (the `config_patches = concat(...)` around lines 17–39).

**Deployed via Octopus only** — never `terraform apply` locally, never `talosctl patch` (drift).

---

## Why not just append another patch

The obvious change is a third `yamlencode` in the `concat()` alongside the `enable_irsa` one. Don't. Both
would set `cluster.apiServer.extraArgs`, and that leaves you depending on Talos merging the two maps rather
than the later one replacing the earlier. If it replaces, `service-account-issuer` and `api-audiences`
disappear — **IRSA breaks**, which on QA means ExternalSecrets, the SM-sourced Grafana creds and etcd-backup
all fail, and the cause looks nothing like "we added an auth webhook".

Build the map in a `local` and emit a single `apiServer` patch instead. No merge semantics involved.

---

## 1. New variable — `variables.tf`

```hcl
variable "enable_aws_iam_authenticator" {
  description = <<-EOT
    Point kube-apiserver at the aws-iam-authenticator webhook, enabling AWS SSO logins
    (the component EKS runs for you; we self-host it on Talos).

    ⚠️ ORDERING: kube-apiserver will NOT START if the webhook config file is missing.
    The DaemonSet (infrastructure/aws-iam-authenticator on the env's flux branch) must
    already be Running and have written /var/lib/aws-iam-authenticator/kubeconfig.yaml
    on EVERY control-plane node before this is set true. Verify per node first.

    Safe to disable: the flag needs the FILE, not a reachable server, and x509 auth is
    unaffected either way.
  EOT
  type        = bool
  default     = false
}
```

## 2. Replace the `enable_irsa` conditional — `main.tf`

Before, in `data "talos_machine_configuration" "controlplane"`:

```hcl
  config_patches = concat(
    [
      yamlencode({
        cluster = {
          network         = { cni = { name = "none" } }
          proxy           = { disabled = true }
          inlineManifests = var.inline_manifests
        }
      })
    ],
    var.enable_irsa ? [
      yamlencode({
        cluster = {
          apiServer = {
            extraArgs = {
              "service-account-issuer" = var.oidc_issuer_url
              "api-audiences"          = "sts.amazonaws.com"
            }
          }
        }
      })
    ] : []
  )
```

After:

```hcl
  config_patches = concat(
    [
      yamlencode({
        cluster = {
          network         = { cni = { name = "none" } }
          proxy           = { disabled = true }
          inlineManifests = var.inline_manifests
        }
      })
    ],
    # ONE apiServer patch, assembled from the feature flags — see locals below.
    # Do not split this into per-feature patches; both would set extraArgs.
    length(local.apiserver_extra_args) > 0 ? [
      yamlencode({
        cluster = {
          apiServer = merge(
            { extraArgs = local.apiserver_extra_args },
            length(local.apiserver_extra_volumes) > 0
              ? { extraVolumes = local.apiserver_extra_volumes }
              : {}
          )
        }
      })
    ] : []
  )
```

## 3. The locals — `main.tf` (top of file) or `locals.tf`

```hcl
locals {
  apiserver_extra_args = merge(
    var.enable_irsa ? {
      "service-account-issuer" = var.oidc_issuer_url
      "api-audiences"          = "sts.amazonaws.com"
    } : {},
    var.enable_aws_iam_authenticator ? {
      # HOST path. The authenticator's own log prints the in-container path
      # (/var/aws-iam-authenticator/...) — do not copy that one.
      "authentication-token-webhook-config-file" = "/var/lib/aws-iam-authenticator/kubeconfig.yaml"
      "authentication-token-webhook-cache-ttl"   = "2m0s"
    } : {},
  )

  # /var is the writable, persistent host path on Talos. Not /etc/kubernetes.
  apiserver_extra_volumes = var.enable_aws_iam_authenticator ? [
    {
      hostPath  = "/var/lib/aws-iam-authenticator"
      mountPath = "/var/lib/aws-iam-authenticator"
      readonly  = true
    }
  ] : []
}
```

## 4. Root module + tfvars

Pass it through wherever `module "talos"` is declared:

```hcl
  enable_aws_iam_authenticator = var.enable_aws_iam_authenticator
```

plus the same `variable` block at root, then per env:

```hcl
# envs/qa.tfvars   (and dev.tfvars — prove it on dev first)
enable_aws_iam_authenticator = true
```

---

## 5. The gate before you deploy

With the new variable at its `false` default, the rendered config must be **byte-identical** to today:

```bash
terraform plan -var-file=envs/dev.tfvars      # expect: No changes.
```

That is the whole point of the `local` refactor — with `enable_aws_iam_authenticator = false` the merge
produces exactly the IRSA-only map the current code emits, and `yamlencode` sorts keys deterministically, so
there is no diff. **If dev shows a diff at `false`, stop** — the refactor is not equivalent and everything
after it is unsafe.

Then flip dev to `true` and plan again: the only change should be the two new `extraArgs` keys and the one
`extraVolumes` entry on the control-plane machine config.

## 6. Deploy

Octopus, dev first. It rolls the control plane. Before you start, in a second terminal:

```bash
KUBECONFIG=~/.kube/op-usxpress-dev-fresh.yaml kubectl get nodes -w
```

x509 auth is unaffected by anything the webhook does — that terminal is the way back in. Watch each apiserver
return before the next node rolls. If one does not come back, the webhook config file was missing on that
node: revert the variable to `false` and redeploy.
