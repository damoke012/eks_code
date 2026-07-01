# Parameterize deploy/terraform/talosconfig-secret-import.tf

## Current content (hardcoded to Dev)

```hcl
# import ID, NOT the secret name. The secret name `op-usxpress-dev/talosconfig`
# For op-usxpress-dev: secret seeded out-of-band on 2026-06-23. This block
import {
  to = aws_secretsmanager_secret.talosconfig
  id = "arn:aws:secretsmanager:us-east-2:700736442855:secret:op-usxpress-dev/talosconfig-jZx93J"
}
```

## Replace with

```hcl
# The talosconfig secret is seeded out-of-band per cluster
# (talosctl generates it during bootstrap; we import the existing SM secret).
# ARN varies per environment — see var.talosconfig_secret_arn set from
# envs/<env>.tfvars.
import {
  to = aws_secretsmanager_secret.talosconfig
  id = var.talosconfig_secret_arn
}
```

## Prerequisites per environment

Before iaac-talos can apply successfully in a new env, someone must:
1. Provision the talosconfig SM secret in that env's AWS account (e.g., `op-usxpress-qa/talosconfig`)
2. Copy its full ARN (including the 6-char SM suffix) into `envs/<env>.tfvars` as `talosconfig_secret_arn`

For Dev: already exists at `arn:aws:secretsmanager:us-east-2:700736442855:secret:op-usxpress-dev/talosconfig-jZx93J`.

For QA: needs seeding — separate follow-up ticket (or as part of INFRA-1585 execution).
