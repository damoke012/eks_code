# Exercise 03 — Cross-account IAM review

**Time:** ~10 minutes

## Scenario

A pod in **Account A** (EKS) needs to read a secret from **Account B** (Secrets Manager). The Terraform in [`main.tf`](main.tf) was scaffolded by a junior engineer. They got `terraform plan` to succeed, but in practice the chain doesn't work end-to-end, and there are security flags worth raising before this ships.

Walk us through what you'd change before approving this PR.

You won't need to run `terraform apply` — read the file, fix what you'd fix, and talk us through your reasoning.

## What we're looking for

- You read the whole chain end-to-end before fixing anything individual
- You can articulate the auth path from pod → secret in plain English, in order, naming every checkpoint
- You raise the **security-relevant** problems clearly (what's the worst that could happen if this ships?)
- You understand what makes cross-account access different from same-account
- You suggest concrete production-grade improvements — not just "make it work", but "make it safe"

## After fixing

We'll ask:

- IRSA vs EKS Pod Identity — pick one for a new cluster and why
- How would you debug this if it weren't working in prod? (Hint: CloudTrail.)
- What's the default session duration on AssumeRole? When would you change it?
