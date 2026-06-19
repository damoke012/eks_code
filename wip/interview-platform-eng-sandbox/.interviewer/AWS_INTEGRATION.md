# AWS account integration plan

The interview sandbox uses our AWS for **Exercise 03** only. We don't need real AWS for:
- Exercise 01 (Go) — local
- Exercise 02 (K8s) — k3d local cluster
- Exercise 04 (TF state split) — discussion, no apply
- Exercise 05 (SLO) — discussion

For Exercise 03 we run `terraform validate` + `terraform plan -refresh=false`. No real resources are created. The candidate edits HCL; we evaluate their code + reasoning.

## Recommended approach: `infra-playground` account, short-lived role

| Decision | Choice | Why |
|---|---|---|
| Which AWS account? | **infra-playground (786352483360)** | Already in our SSO map; isolated; safe to test against |
| What credentials? | Short-lived STS via SSO + read-only role | Zero secret exfiltration risk |
| How does codespace get them? | Either (a) candidate runs `aws sso login` interactively, or (b) we inject via Codespaces Secrets | (a) is cleanest if candidate has SSO; (b) for external candidates |
| Permissions scope | `IAMReadOnlyAccess` + `SecretsManagerReadWrite` (scoped to interview-sandbox prefix) | Lets `terraform plan` reach IAM + SM APIs without write access elsewhere |

## Setup steps (one-time, ~30 min)

1. **Create the role** in `infra-playground` (786352483360):

```bash
aws --profile infra-playground iam create-role \
  --role-name interview-sandbox-readonly \
  --assume-role-policy-document file://trust-policy.json

aws --profile infra-playground iam attach-role-policy \
  --role-name interview-sandbox-readonly \
  --policy-arn arn:aws:iam::aws:policy/IAMReadOnlyAccess

aws --profile infra-playground iam put-role-policy \
  --role-name interview-sandbox-readonly \
  --policy-name SecretsRead \
  --policy-document file://secrets-read.json
```

Trust policy (`trust-policy.json`):
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "AWS": "arn:aws:iam::786352483360:root"
    },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": { "aws:RequestTag/Purpose": "interview" }
    }
  }]
}
```

Secrets-read policy (`secrets-read.json`):
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["secretsmanager:Describe*", "secretsmanager:Get*", "secretsmanager:List*"],
    "Resource": "arn:aws:secretsmanager:*:786352483360:secret:interview-sandbox/*"
  }]
}
```

2. **Pre-create a fake secret** the exercise references:

```bash
aws --profile infra-playground secretsmanager create-secret \
  --name interview-sandbox/db-creds \
  --secret-string '{"engine":"postgres","username":"demo","password":"demo"}'
```

3. **Add a Codespaces Secret** for short-lived creds (optional — only if candidate doesn't have SSO):

In the GitHub repo Settings → Codespaces → Repository secrets:
- `AWS_ACCESS_KEY_ID` — short-lived (1h max) from `aws sts assume-role`
- `AWS_SECRET_ACCESS_KEY` — same
- `AWS_SESSION_TOKEN` — same
- Rotate before each interview

OR — simpler — have the interviewer's terminal session pre-credential the codespace via `aws configure sso` and the candidate inherits.

## Per-interview workflow

10 min before interview:
1. Refresh STS creds: `aws sts assume-role --role-arn arn:aws:iam::786352483360:role/interview-sandbox-readonly --role-session-name interview-$(date +%s) --duration-seconds 3600`
2. Update GitHub Codespaces Secrets with the temporary creds (or skip if using interactive SSO)
3. Spin up the candidate's codespace
4. Verify: `aws sts get-caller-identity` returns the interview-sandbox role

After interview:
1. Delete the codespace (auto-deletes after 30 days idle anyway)
2. Rotate the STS creds (they'll expire on their own in 1h)

## Why we don't use prod or qa accounts

- Blast radius — even read-only credentials in a candidate's hands is a leak surface
- Auditability — we want a clean CloudTrail attribution for "this came from interview-sandbox"
- Cost attribution — sandbox account makes it easy to see if a candidate accidentally creates resources

## What we don't give the candidate

- Production account access (any of: usx-dev, usx-qa, ops-controller, infra-common, etc.)
- Write access to anything outside the `interview-sandbox/*` SM secret prefix
- IAM write access — they can READ IAM (needed for `terraform plan` to introspect roles) but not create/modify
- Cross-account assume role chains into anything real
