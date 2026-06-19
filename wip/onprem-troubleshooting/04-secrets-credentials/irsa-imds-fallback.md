# IRSA → IMDS Cryptic Fallback on Non-EKS

**Symptom:**
- Pod log (RW, app, anything using AWS SDK) shows:
  ```
  error sending request for url (http://169.254.169.254/latest/api/token): operation timed out
  ```
- Followed by AWS SDK error like `failed to retrieve credentials` or `dispatch failure`
- Or RW-specific: `opendal::services s3 ... read failed Unexpected ... loading credential to sign http request`
- Pod has `AWS_ROLE_ARN` + `AWS_WEB_IDENTITY_TOKEN_FILE` env vars (IRSA properly configured) but SDK still tries IMDS

**Root cause:**
The AWS SDK credential provider chain on EC2 instances includes IMDS (169.254.169.254) as a fallback. On Talos on-prem, there's no IMDS endpoint — the request hits a non-route and times out.

If the SDK reaches IMDS, it means an earlier provider in the chain failed silently. Most commonly:
1. **DNS broken** — SDK tried to call `sts.us-east-2.amazonaws.com` for AssumeRoleWithWebIdentity, DNS lookup timed out, fell through to IMDS
2. **Token file empty/invalid** — `AWS_WEB_IDENTITY_TOKEN_FILE` points to a path with no valid token
3. **OIDC issuer not reachable from STS** — AWS STS can't verify the projected token because the OIDC JWKS URL isn't publicly reachable (CloudFront down, etc.)
4. **Role trust policy mismatch** — the IRSA role's trust policy doesn't include this cluster's OIDC issuer / subject pattern

**IaC coverage:** ⚠ (IRSA wiring is codified; detection PromRule planned in Track 4 NEW)

**IaC location:**
- `iaac-talos/deploy/terraform/modules/irsa/` — projected SA token + role + OIDC issuer setup
- `iaac-talos-flux-platform/infrastructure/pod-identity-webhook/` — mutates pods with SAs that have `eks.amazonaws.com/role-arn` annotation
- AWS account: `iaac-route53-zone` + IRSA role trust policy
- Planned: PromRule `IRSAFailureCascade` (Track 4 NEW)

### Resolution via IaC

Once correctly wired, IRSA works automatically:
1. Pod boots with SA annotated `eks.amazonaws.com/role-arn: arn:aws:iam::<account>:role/<role>`
2. `pod-identity-webhook` mutates pod spec to inject `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`, and the projected SA token volume
3. AWS SDK reads token from file, calls STS AssumeRoleWithWebIdentity, gets temp creds, uses them for AWS calls

### Manual resolution

**Step 1 — Verify IRSA env vars are present (rules out webhook race):**

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

kubectl $KCONFIG -n <ns> get pod <name> -o yaml | \
  grep -E "AWS_WEB_IDENTITY_TOKEN_FILE|AWS_ROLE_ARN|serviceAccountToken:|name: aws-iam-token" | head -10
# Expect: 4 lines minimum (env vars + volume mount + token projection)
```

If MISSING: see [[pod-identity-webhook-race]] — recreate the pod after confirming webhook is healthy.

**Step 2 — Verify the projected token file is valid:**

```bash
kubectl $KCONFIG -n <ns> exec <pod> -- ls -la /var/run/secrets/eks.amazonaws.com/serviceaccount/
# Expect: token file present, non-zero size

kubectl $KCONFIG -n <ns> exec <pod> -- cat /var/run/secrets/eks.amazonaws.com/serviceaccount/token | head -c 50
# Expect: a JWT prefix (eyJhbGc...)
```

**Step 3 — Verify STS DNS resolution from inside the pod:**

```bash
kubectl $KCONFIG -n <ns> exec <pod> -- nslookup sts.us-east-2.amazonaws.com 2>&1 | tail -10
# OK: returns multiple A records
# BROKEN: connection timed out → see [[cluster-dns-failure]]
```

**Step 4 — Verify trust policy is correct (AWS side):**

```bash
ROLE_NAME=<irsa-role-name>
aws --profile usx-dev iam get-role --role-name $ROLE_NAME --query 'Role.AssumeRolePolicyDocument'
# Check Federated principal is the OIDC issuer URL (CloudFront)
# Check Condition.StringEquals includes the SA's namespace + name
```

**Step 5 — If trust policy is correct but pod still hits IMDS, force pod restart:**

```bash
kubectl $KCONFIG -n <ns> delete pod <name>
# StatefulSet/Deployment respawns; fresh pod attempts IRSA from scratch
```

### Verification

```bash
# 1. Pod's first S3 / SM / STS call succeeds (no IMDS error)
kubectl $KCONFIG -n <ns> logs <pod> --tail=100 | grep -iE "imds|169\.254\.169\.254"
# Expect: empty

# 2. AWS SDK successfully assumed role
kubectl $KCONFIG -n <ns> logs <pod> --tail=100 | grep -iE "assumeRole|STS|sts\.us-east-2"
# Look for successful STS response
```

### Prevention

- **PromRule `IRSAFailureCascade`** (Track 4 NEW): probe SA tokens against STS every 5 min, alert if any fail
- **DNS health PromRule** (Track 4 NEW) — primary upstream of this issue
- **Trust policy validation** at PR time — automated check that the IAM role trust policy includes the current cluster's OIDC issuer

### Related

- [[cluster-dns-failure]] — most common upstream cause (STS DNS broken)
- [[pod-identity-webhook-race]] — when env vars are missing entirely
- [[clustersecretstore-dns-dependency]] — sister symptom
- Memory: `[ssm_eks_data_fallback_progress]` — OIDC fallback work

### Memory pointers

- `[ssm_eks_data_fallback_progress]` — END-TO-END GREEN 2026-04-08
- `[Session state Jun 19]` — RW meta hit this exact symptom (IMDS timeout) during DNS-broken window; resolved after CN fix → DNS → pod restart
