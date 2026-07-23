// secrets.tf — SecretsManager secrets for RisingWave.
//
// Goes in variant-inc/iaac-risingwave-onprem: terraform/secrets.tf
//
// WHY: manifests/op-usxpress-qa/ has five ExternalSecrets reading
// op-usxpress-qa/risingwave/*, and NONE of those SM secrets exist. Without
// this file someone has to hand-run `aws secretsmanager create-secret` five
// times per environment — exactly the manual step prod is supposed to not have.
// Worse, a missing SM secret surfaces as an ExternalSecret that never goes
// Ready, or (if seeded with junk) one that reports SecretSynced=True over a
// value that does not work. That failure mode has already cost us twice: Wiz
// (6-char placeholders synced green) and QA etcd (PLACEHOLDER_POPULATE synced
// green for 13 days).
//
// Four of the five are DERIVABLE and therefore Terraform's job. Only the
// vendor-issued license key is genuinely external.
//
// Shapes are taken from the ExternalSecrets' remoteRef.property values —
// every secret is a JSON object, not a plain string:
//   postgres                  {"username","password"}
//   root                      {"password"}
//   svc-reporting             {"password"}
//   secret_store_private_key  {"RW_SECRET_STORE_PRIVATE_KEY_HEX"}
//   console_license_key       {"RW_LICENSE_KEY"}
//
// ⚠️ PREREQUISITE — verify before relying on any of this: External Secrets
// Operator reads SM with ITS OWN IRSA role, not RisingWave's. If the ESO role's
// policy does not cover ${var.cluster_name}/risingwave/*, every ExternalSecret
// here fails regardless of the values being correct. Check the ESO role policy
// in iaac-talos before merging.

terraform {
  required_providers {
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }
}

locals {
  sm_prefix = "${var.cluster_name}/risingwave"
}

// ── Generated values ────────────────────────────────────────────────────────
// special = false: these land in connection strings and shell env; punctuation
// causes quoting bugs that only show up under load.
resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "random_password" "root" {
  length  = 32
  special = false
}

resource "random_password" "svc_reporting" {
  length  = 32
  special = false
}

// RW_SECRET_STORE_PRIVATE_KEY_HEX must be hex, hence random_id not
// random_password. 32 bytes -> 64 hex chars.
resource "random_id" "secret_store_private_key" {
  byte_length = 32
}

// ── Postgres metastore credentials ──────────────────────────────────────────
resource "aws_secretsmanager_secret" "postgres" {
  name = "${local.sm_prefix}/postgres"
  // 0 so a teardown/rebuild can recreate the same name immediately instead of
  // hitting the 7-day deletion window.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "postgres" {
  secret_id = aws_secretsmanager_secret.postgres.id
  secret_string = jsonencode({
    username = "risingwave"
    password = random_password.postgres.result
  })
}

// ── RisingWave root user ────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "root" {
  name                    = "${local.sm_prefix}/root"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "root" {
  secret_id     = aws_secretsmanager_secret.root.id
  secret_string = jsonencode({ password = random_password.root.result })
}

// ── svc-reporting service account ───────────────────────────────────────────
resource "aws_secretsmanager_secret" "svc_reporting" {
  name                    = "${local.sm_prefix}/svc-reporting"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "svc_reporting" {
  secret_id     = aws_secretsmanager_secret.svc_reporting.id
  secret_string = jsonencode({ password = random_password.svc_reporting.result })
}

// ── Secret-store encryption key — GENERATE ONCE, NEVER ROTATE ───────────────
// RisingWave encrypts stored secrets with this key. Rotating it makes every
// previously-encrypted secret undecryptable. random_id is stable in state, and
// ignore_changes is the second line of defence: if this resource is ever
// touched by hand or a provider upgrade changes generation, Terraform must not
// overwrite the live value.
resource "aws_secretsmanager_secret" "secret_store_private_key" {
  name                    = "${local.sm_prefix}/secret_store_private_key"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "secret_store_private_key" {
  secret_id = aws_secretsmanager_secret.secret_store_private_key.id
  secret_string = jsonencode({
    RW_SECRET_STORE_PRIVATE_KEY_HEX = random_id.secret_store_private_key.hex
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

// ── RisingWave Console license key — THE ONE EXTERNAL VALUE ─────────────────
// Vendor-issued; Terraform cannot derive it. TF owns the WRAPPER and seeds a
// placeholder so the rebuild is unblocked; a human injects the real value once
// and ignore_changes stops future applies clobbering it. Same pattern as the
// Grafana azure-ad secret in iaac-talos.
//
// Inject with:
//   aws secretsmanager put-secret-value --profile usx-qa \
//     --secret-id op-usxpress-qa/risingwave/console_license_key \
//     --secret-string '{"RW_LICENSE_KEY":"<vendor key>"}'
//   kubectl -n risingwave annotate externalsecret <name> force-sync="$(date +%s)" --overwrite
//
// ⚠️ A license key is also a COST/ENTITLEMENT decision — confirm QA is covered
// by the existing RisingWave agreement before enabling Console there.
resource "aws_secretsmanager_secret" "console_license_key" {
  name                    = "${local.sm_prefix}/console_license_key"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "console_license_key" {
  secret_id     = aws_secretsmanager_secret.console_license_key.id
  secret_string = jsonencode({ RW_LICENSE_KEY = "PLACEHOLDER_INJECT_REAL_LICENSE" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────
// ARNs only. Never output secret values — they land in tfstate plaintext and in
// Octopus deploy logs.
output "risingwave_secret_arns" {
  description = "SecretsManager ARNs for the RisingWave platform secrets."
  value = {
    postgres                 = aws_secretsmanager_secret.postgres.arn
    root                     = aws_secretsmanager_secret.root.arn
    svc_reporting            = aws_secretsmanager_secret.svc_reporting.arn
    secret_store_private_key = aws_secretsmanager_secret.secret_store_private_key.arn
    console_license_key      = aws_secretsmanager_secret.console_license_key.arn
  }
}
