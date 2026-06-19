# Exercise 03 — Cross-account IAM review (INTERVIEWER SOLVE NOTES)

**For interviewer eyes only. Never share with candidates. Never push to a public/candidate-facing repo.**

## What the exercise tests

The candidate inherits a Terraform file that **passes `terraform plan`** but is broken end-to-end and has security issues. We're testing:

1. **Whole-chain reading** — does the candidate trace pod → role → STS → secret in order, or do they patch one thing at a time without context?
2. **Cross-account understanding** — can they articulate why cross-account is structurally different from same-account?
3. **Security depth** — do they understand confused deputy, ExternalId, dual-layer authorization (IAM + resource policy)?
4. **Senior judgment** — beyond "make it work," do they think about least-privilege and what's safe to ship?

A candidate who fixes one bug but doesn't see the others is mid. A candidate who finds all three plus articulates the reasoning is strong.

## The three bugs (and one structural issue)

Read the candidate's `main.tf` to remind yourself of the exact code (`exercises/03-aws-cross-account/main.tf`). The TODO comments give *hints* to a junior but **do not name the bugs**. A senior should diagnose without relying on the TODOs.

### Bug 1 — Source pod role grants the wrong action

```hcl
# lines 61-74
resource "aws_iam_role_policy" "pod_source_perms" {
  provider = aws.account_a
  role     = aws_iam_role.pod_source_role.id
  policy = jsonencode({
    Statement = [{
      Action   = "secretsmanager:GetSecretValue"
      Resource = "arn:aws:secretsmanager:us-east-1:${var.account_b_id}:secret:demo-app/db-creds-*"
    }]
  })
}
```

The pod role in Account A has `GetSecretValue` permission, but it has no `sts:AssumeRole`. The pod would try to call `secretsmanager:GetSecretValue` directly across accounts — **AWS will reject this with AccessDenied**. Cross-account access requires assuming a role in the target account first.

### Bug 2 — Trust policy on cross-account role accepts the entire AWS world

```hcl
# lines 83-92
assume_role_policy = jsonencode({
  Statement = [{
    Effect = "Allow"
    Principal = { AWS = "*" }
    Action = "sts:AssumeRole"
  }]
})
```

`Principal: { AWS = "*" }` means **any AWS principal in any account can assume this role**. Worst case: an attacker in any AWS account can assume this role and read the secret.

### Bug 3 — Secret has no resource policy

The secret `demo-app/db-creds` exists in Account B. For cross-account access to a Secrets Manager secret, **both** must be true:
- The assumed role's permission policy allows `GetSecretValue` (✅ already there in Bug 1's fix)
- The secret's **resource policy** allows the assumed role to call `GetSecretValue` (❌ missing entirely)

This is the **dual-layer authorization** rule that catches a lot of mid-level engineers — they fix the IAM side and assume the resource side is unnecessary. For same-account access, AWS often accepts IAM-only. For cross-account, both layers are required.

### Structural issue — no ExternalId / confused deputy protection

Even with the trust policy tightened to a specific role, in vendor-customer or shared-platform scenarios you should also use `ExternalId` to prevent the confused-deputy attack. Worth flagging during the discussion.

---

## Deep walkthrough — Bug 1

### Layer 1 — what the candidate sees

Lines 61-74 of `main.tf`:
```hcl
resource "aws_iam_role_policy" "pod_source_perms" {
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = "arn:aws:secretsmanager:us-east-1:${var.account_b_id}:secret:demo-app/db-creds-*"
    }]
  })
}
```

The TODO comment (`# Couldn't get AssumeRole working ... granted GetSecretValue directly`) is a hint, but a senior should diagnose this without relying on it.

### Layer 2 — plain English

"A pod in Account A is trying to read a secret in Account B. The junior gave the pod permission to call `GetSecretValue` directly on the cross-account ARN. That doesn't work — cross-account access requires assuming a role first."

### Layer 3 — mechanism (how cross-account access actually works)

The end-to-end auth chain for cross-account secret access:

1. **Pod has IRSA** → ServiceAccount has `eks.amazonaws.com/role-arn` annotation pointing to `pod_source_role` in Account A
2. **Pod-identity-webhook injects** `AWS_ROLE_ARN` + `AWS_WEB_IDENTITY_TOKEN_FILE` into the container env
3. **AWS SDK in the pod**:
   - Reads the web identity token
   - Calls `sts:AssumeRoleWithWebIdentity` → gets temporary credentials for `pod_source_role` in Account A
4. **App code then needs to access the secret in Account B**. Two options:
   - **WRONG (what the junior wrote)**: app calls `secretsmanager:GetSecretValue` directly with Account A creds → Account B says "this caller has no permission on my secret" → AccessDenied
   - **RIGHT**: app calls `sts:AssumeRole` to assume `cross_account_reader` in Account B → gets new temporary creds for the Account B role → THEN calls `secretsmanager:GetSecretValue` with those creds → succeeds

The pod's source role needs `sts:AssumeRole` permission on the target role's ARN, NOT direct `secretsmanager:*` permissions.

### Layer 4 — runtime failure mode

If you actually deployed this:
- Pod starts, IRSA assumes `pod_source_role` ✅
- App calls `secretsmanager:GetSecretValue` against the Account B ARN
- AWS evaluates: caller is `pod_source_role` in Account A; resource is in Account B
- AWS checks: does the caller have IAM permission? Yes (we gave it `GetSecretValue`).
- AWS checks: does the resource (secret in Account B) have a policy allowing this caller? **No resource policy exists.**
- **AccessDenied**: `User: arn:aws:sts::111111111111:assumed-role/demo-pod-secret-reader/... is not authorized to perform: secretsmanager:GetSecretValue on resource: arn:aws:secretsmanager:us-east-1:222222222222:secret:demo-app/db-creds-...`

### Layer 5 — fix

```hcl
resource "aws_iam_role_policy" "pod_source_perms" {
  provider = aws.account_a
  role     = aws_iam_role.pod_source_role.id
  name     = "pod-assume-role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = aws_iam_role.cross_account_reader.arn
    }]
  })
}
```

The pod's role now has permission to assume the cross-account role. That's the only permission it needs at this layer.

### Layer 6 — probes to ask

| Probe | Strong | Weak |
|---|---|---|
| "Why doesn't the original work?" | "Direct cross-account API calls aren't allowed; you must AssumeRole first" | "I'm not sure, AWS is confusing" |
| "What's the auth chain end-to-end?" | Lists IRSA → AssumeRoleWithWebIdentity → AssumeRole → GetSecretValue | Skips steps or names them wrong |
| "Why does same-account direct access work but cross-account doesn't?" | "Same account = single trust boundary. Cross account = the target account has to opt in via resource policy or role trust" | Treats them as the same |
| "Where does the cross-account role's credentials come from?" | "STS issues temporary creds with a TTL after AssumeRole" | "AWS handles it" |

### Layer 7 — strong vs weak phrases

**STRONG**
- "Cross-account = AssumeRole first, then act."
- "The source role only needs `sts:AssumeRole`, not the data-plane permission."
- "Temporary credentials issued by STS — short TTL."

**WEAK**
- "Just add the permission and it'll work." (Same-account thinking applied wrongly.)
- "We could use access keys instead." (Worse, not the right fix.)

---

## Deep walkthrough — Bug 2

### Layer 1 — what the candidate sees

Lines 83-92:
```hcl
assume_role_policy = jsonencode({
  Statement = [{
    Effect = "Allow"
    Principal = { AWS = "*" }
    Action = "sts:AssumeRole"
  }]
})
```

TODO comment says "open during dev so I could test." Doesn't name what's wrong with shipping it.

### Layer 2 — plain English

"This role's trust policy says 'anyone in any AWS account can assume me.' That's how you let in the entire internet of AWS principals — random Amazon customers included. Worst case: an attacker in any account assumes this role, reads our secret, exfiltrates."

### Layer 3 — mechanism (how trust policies work)

The trust policy is the **role's bouncer**. It evaluates:
- WHO can assume me (Principal)
- WHEN can they (Conditions)

`Principal: { AWS = "*" }` says: any AWS principal anywhere. Combined with `Action: sts:AssumeRole` and no Condition block, this is fully open.

**This is one of the worst misconfigurations possible in IAM.** It's an "open S3 bucket of roles."

### Layer 4 — runtime failure mode

- Anyone running `aws sts assume-role --role-arn arn:aws:iam::222222222222:role/cross-account-secret-reader` from ANY AWS account succeeds
- They get temporary credentials for the role
- They can call `secretsmanager:GetSecretValue` on `demo-app/db-creds`
- Secret exfiltrated

This isn't theoretical — AWS Trust Advisor and most security scanners (Wiz, Orca, Prowler) flag this exact pattern immediately.

### Layer 5 — fix

```hcl
assume_role_policy = jsonencode({
  Version = "2012-10-17"
  Statement = [{
    Effect = "Allow"
    Principal = {
      AWS = aws_iam_role.pod_source_role.arn
    }
    Action = "sts:AssumeRole"
    Condition = {
      StringEquals = {
        "sts:ExternalId"       = "usx-demo-app-v1"
        "aws:PrincipalAccount" = var.account_a_id
      }
    }
  }]
})
```

Three things tightened:
1. **Principal**: specific source role ARN only
2. **ExternalId**: a shared secret that the caller must include in the AssumeRole request
3. **PrincipalAccount**: belt-and-suspenders — even if the role ARN somehow resolved differently, the caller must be in our Account A

### What is ExternalId / confused deputy?

The **confused deputy** problem (from the classic 1988 Hardy paper):

> A vendor service ("the deputy") is allowed to act on its customers' behalf. An attacker tricks the deputy into acting on the wrong customer's behalf because the deputy has no way to distinguish "I'm acting for customer X" from "I'm acting for customer Y".

In AWS terms:
- Imagine a third-party SaaS (say, a monitoring vendor) has a role in their AWS account that assumes roles in their customers' accounts
- A normal customer trusts that role: "Allow vendor-account:role/MonitoringRole to assume my MyReadRole"
- An attacker becomes a customer of the same vendor and asks the vendor: "please assume MyReadRole in account 999..." (the victim's account)
- The vendor's role IS the same role for all customers — its trust policy in your account only checks "is the caller the vendor's role?" → yes → access granted
- Attacker now reads your data

**ExternalId is the fix**: vendor includes a per-customer-unique ID when calling AssumeRole. Customer's trust policy requires that specific ID. If the attacker doesn't know the victim's ExternalId, the call fails.

For internal cross-account (pod-A → role-in-B, all within USX), ExternalId is less critical because there's no third party. But it's still good practice as defense-in-depth.

### Layer 6 — probes to ask

| Probe | Strong | Weak |
|---|---|---|
| "What's wrong with `Principal: { AWS = '*' }`?" | "Allows anyone in any account to assume" | "It's not specific enough" (vague) |
| "Explain confused deputy in your own words" | Vendor-customer scenario with ExternalId fix | Doesn't know the term |
| "When do you NOT need ExternalId?" | "Internal-only assume chains where both sides are trusted. Still good practice though." | "Always need it" / "Never need it" |
| "Walk me through how aws:PrincipalAccount works" | "Trusted account ID — caller must be from that account, even if their role is from elsewhere" | Doesn't know |

### Layer 7 — strong vs weak phrases

**STRONG**
- "Principal star is the worst-case open assume."
- "I'd scope to the specific role ARN + add ExternalId + PrincipalAccount as defense-in-depth."
- "ExternalId protects against confused deputy when there's a third-party deputy."
- "Trust policy is the role's bouncer — be specific."

**WEAK**
- "Just scope it to our account." (Half-fix — better but ExternalId is still good practice for senior signal.)
- "We can use a SCP instead." (SCPs are for org-level; trust policy is the right layer.)
- Doesn't know ExternalId.

---

## Deep walkthrough — Bug 3

### Layer 1 — what the candidate sees

The exercise doesn't define a `aws_secretsmanager_secret_policy` resource. The secret itself is provisioned "elsewhere" (per the comment).

### Layer 2 — plain English

"Cross-account access to a Secrets Manager secret requires **both** the IAM role policy AND the secret's resource policy to allow the action. We have the role-side policy. The secret-side is missing."

### Layer 3 — mechanism (dual-layer authorization)

For same-account access:
- IAM role has permission → AWS allows.
- (Secret resource policy is optional; defaults to allow.)

For cross-account access:
- The cross-account caller must be **explicitly allowed by the resource policy** on the secret, AND have IAM permission on its own side
- If either layer is missing, the action is denied

Same logic applies to:
- S3 bucket policies (cross-account access requires bucket policy)
- KMS key policies (cross-account decrypt requires key policy)
- SQS queue policies, SNS topic policies, etc.

It's the AWS cross-account dual-layer rule. Worth memorizing.

### Layer 4 — runtime failure mode

Without the resource policy:
- Pod assumes `cross_account_reader` ✅
- Cross-account role has IAM permission `GetSecretValue` ✅
- Pod calls `GetSecretValue`
- AWS evaluates resource policy on the secret → not present → falls back to default-deny for cross-account
- **AccessDenied**: `... is not authorized to perform: secretsmanager:GetSecretValue on resource: ... because no resource-based policy allows the secretsmanager:GetSecretValue action`

### Layer 5 — fix

```hcl
resource "aws_secretsmanager_secret_policy" "demo_db_creds" {
  provider   = aws.account_b
  secret_arn = aws_secretsmanager_secret.demo_db_creds.arn   # AWS provider v5 — NOT secret_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.cross_account_reader.arn }
      Action    = "secretsmanager:GetSecretValue"
      Resource  = "*"
    }]
  })
}
```

**Gotcha**: AWS provider v5 uses `secret_arn` (not `secret_id` like v4 did). `terraform validate` catches this; a strong candidate either knows or validates and fixes.

### Layer 6 — probes to ask

| Probe | Strong | Weak |
|---|---|---|
| "Why do we need a resource policy?" | Cross-account dual-layer rule | "Because the IAM side wasn't enough" (vague) |
| "Does same-account need a resource policy?" | "Not usually — IAM alone is sufficient" | "Always need it" |
| "What other AWS resources have this dual-layer pattern?" | S3, KMS, SQS, SNS | Lists only Secrets Manager |
| "What happens at runtime without the resource policy?" | AccessDenied citing no resource policy | "It fails" (no detail) |

### Layer 7 — strong vs weak phrases

**STRONG**
- "Cross-account = dual layer; role's IAM policy + resource's resource policy both must allow."
- "S3, KMS, SQS, SNS — same pattern."
- "AWS provider v5 takes `secret_arn`, not `secret_id`. `terraform validate` catches that."

**WEAK**
- "I'd just add the permission on the role." (Missed the resource policy entirely.)
- Doesn't know about cross-account dual layer.

---

## Follow-up questions (after the bugs are fixed)

The EXERCISE.md ends with three follow-ups. Use these to test depth.

### "IRSA vs EKS Pod Identity — pick one for a new cluster and why"

**STRONG answers** include:

- **EKS Pod Identity is newer (GA Nov 2023)** — replaces the OIDC-based IRSA model. No OIDC provider to configure per cluster.
- **Trust policy**: with IRSA you encode the OIDC issuer URL + sub claim in the trust policy. With Pod Identity, you trust `pods.eks.amazonaws.com` and AWS handles the mapping via the EKS API.
- **Practical implications**:
  - IRSA: trust policy is rebuilt per-cluster (since OIDC URL changes); tight coupling between cluster and IAM
  - Pod Identity: roles can be reused across clusters more easily; less IAM churn
  - Pod Identity needs the `eks-pod-identity-agent` add-on running on the cluster
- **Recommendation for new cluster**: Pod Identity if you're greenfield and on EKS-supported region. Stick with IRSA only if you have an existing pattern that works and migration cost isn't worth it.

**WEAK**: doesn't know what Pod Identity is; treats them as identical.

### "How would you debug this if it weren't working in prod? Hint: CloudTrail."

**STRONG**:
- Enable CloudTrail (assume on)
- Look in CloudTrail for the `AssumeRole` call → see what role was assumed, from where, with what conditions
- Look for `GetSecretValue` calls → see the error message (AccessDenied with the specific reason)
- The CloudTrail event's `userIdentity.arn` tells you exactly who called what
- For cross-account: check CloudTrail in BOTH accounts (caller's account sees the AssumeRole; target account sees the GetSecretValue)
- Use CloudTrail Insights or Lake for SQL-style queries if available

**WEAK**: "I'd look at logs" without naming CloudTrail; doesn't know cross-account CloudTrail patterns.

### "What's the default session duration on AssumeRole? When would you change it?"

**STRONG**:
- Default 1 hour, max 12 hours (for AssumeRole / AssumeRoleWithWebIdentity / AssumeRoleWithSAML)
- Configured via `DurationSeconds` parameter in the API call or `maxSessionDuration` on the role
- **Increase** for long-running jobs (data pipelines, large migrations) so you don't have to refresh
- **Decrease** for high-risk roles (security-sensitive ops) to limit blast radius if creds leak
- SDKs typically auto-refresh before expiry — strong candidate notes this

**WEAK**: doesn't know the default; doesn't think about trade-offs.

---

## What to do during the exercise

### Open with

> "There's a `main.tf` in `exercises/03-aws-cross-account`. The junior who wrote it got `terraform plan` to succeed, but the chain doesn't actually work end-to-end and there are security issues. Walk me through what you'd change before approving this PR. You don't need to run `terraform apply` — just read the file, fix what you'd fix, and talk us through your reasoning."

### While they work

- **Bug 1 is the easiest to spot** — the TODO comment is a hint. Don't expect points just for finding it; expect them to articulate the auth chain.
- **Bug 2 is the security headline** — strong candidates flag this as the worst of the three from a security standpoint.
- **Bug 3 is the depth test** — finding the missing resource policy without prompting is a strong signal. If they miss it, ask: "anything missing on the secret side?"
- **ExternalId** — even if they fix the trust policy without ExternalId, ask them about confused deputy. Their answer tells you their depth.

### When they finish

Ask the three follow-up questions. These spread the depth across IRSA/Pod Identity, debugging, and session management — three different angles.

## Scoring rubric

| Tier | Signal |
|---|---|
| **STRONG hire** | Finds all 3 bugs unprompted. Articulates the auth chain end-to-end. Knows ExternalId + confused deputy. Mentions dual-layer authorization. Knows AWS provider v5 `secret_arn` (or catches via validate). Strong on follow-ups (Pod Identity, CloudTrail, session duration). |
| **Hire** | Finds Bug 1 + 2 unprompted; Bug 3 with a small nudge ("anything else?"). Auth chain mostly correct. Knows ExternalId by name. Follow-ups mostly correct. |
| **Borderline** | Finds Bug 1, may need help on 2 + 3. Auth chain has gaps. Doesn't know ExternalId until prompted. Follow-ups vague. |
| **No hire** | Patches bugs individually without seeing the chain. Doesn't understand cross-account is structurally different. Suggests "use access keys" or "give it admin." Doesn't know what Pod Identity is. |

## Time budget

- ~10 min total
- 2 min reading the file
- 5 min on the bugs (target: identify all 3, fix at least 2)
- 3 min on follow-ups

If they're stuck reading at minute 4 with no progress, ask: "What's the first thing you'd check?"
