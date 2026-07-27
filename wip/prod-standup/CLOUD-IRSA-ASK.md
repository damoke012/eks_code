# Ask → Cloud team: prod IRSA bootstrap (op-usxpress-prod)

**This is the one genuine external dependency left for a functional prod platform.**
Same thing you already provisioned for QA — I've listed QA's live values as the exact
template so this is a "make the prod equivalent" request, not a design discussion.

## What I need

An IRSA trust path for the on-prem prod Talos cluster, in AWS account **937464026810**
(ops-controller / usxpress-prod), mirroring QA's setup in `527101283767`:

1. **S3 OIDC-discovery bucket** — `op-usxpress-prod-irsa-oidc-v2`
   (QA: `op-usxpress-qa-irsa-oidc-v2`)
2. **CloudFront distribution** fronting it → the OIDC issuer URL
   (QA issuer: `https://d2t7d36wmf0hbm.cloudfront.net`)
3. **IAM OIDC provider** registered for that issuer
4. **Bootstrap role ARN** the cluster assumes — `ONPREM_BOOTSTRAP_ROLE_ARN_PROD`
   (QA pattern: per-workload roles like `op-usxpress-qa-<workload>`, trust sub
   `system:serviceaccount:<ns>:<sa>`)

## Why it blocks

On-prem Talos has no instance profile, so **every** AWS-touching platform component
authenticates through this OIDC path: external-secrets/ESO reading Secrets Manager,
external-dns writing Route53, velero + etcd-backup writing S3. Until it exists, prod's
ExternalSecrets can't sync — Grafana and Argo CD come up with no admin credential, and
etcd has no off-cluster backup. The cluster itself stands up fine without it; the
platform on top does not.

## What's already done on our side

- Account confirmed 937464026810, DNS `usxpress-prod.com`, state bucket, VIP `10.10.82.52`
- All Octopus vars staged (`enable_irsa=false` until you deliver this, then we flip true)
- `irsa_oidc_bucket_name` / `irsa_role_arn` are the only two vars waiting on your values

## Turnaround

This is the long pole — the cluster can stand up in parallel, but it's not usable until
this lands. If you can mirror QA's setup this week, prod platform follows immediately.
