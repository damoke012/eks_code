# Pod-Identity-Webhook Mutation Race (IRSA Env Vars Missing)

**Symptom:**
- Pod has ServiceAccount annotated `eks.amazonaws.com/role-arn` but pod's env vars don't show `AWS_ROLE_ARN` or `AWS_WEB_IDENTITY_TOKEN_FILE`
- AWS SDK in the pod falls through to IMDS (see [[irsa-imds-fallback]])
- Other pods in the same cluster using the same SA DO have the env vars (they were created after webhook was healthy)

**Root cause:**
The `pod-identity-webhook` MutatingWebhookConfiguration intercepts pod creation. When a pod's SA has the IRSA annotation, the webhook mutates the pod spec to inject:
- `AWS_ROLE_ARN` env var
- `AWS_WEB_IDENTITY_TOKEN_FILE` env var
- Projected ServiceAccount token volume + mount

If a pod is created BEFORE the webhook is ready (cluster cold start, webhook pod restart, network blip), the mutation is silently skipped. The pod runs forever without IRSA, falling back to IMDS.

The webhook DOESN'T retroactively mutate existing pods — only deletion + recreation will trigger the mutation.

**IaC coverage:** ⚠ (webhook itself is codified; priority barrier to prevent race is planned in Track 5 NEW)

**IaC location:**
- `iaac-talos-flux-platform/infrastructure/pod-identity-webhook/` — webhook Deployment + MutatingWebhookConfiguration
- Planned: priority class + readiness barrier so app pods don't schedule before webhook is healthy (Track 5 NEW)

### Resolution via IaC

For steady state: webhook is healthy, every pod gets mutated. No issue.

For cold start or webhook restart: planned IaC is a `PriorityClass` `system-critical` for the webhook plus a startup probe that signals "ready to mutate" before allowing other workloads to schedule. Until shipped, manual recovery is needed.

### Manual resolution

**Step 1 — Verify the webhook is healthy now:**

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

# Webhook Deployment
kubectl $KCONFIG -n pod-identity-webhook get deploy
# Expect: 1/1 Ready (alt: -n kube-system, depending on install)

# Mutating webhook config registered
kubectl $KCONFIG get mutatingwebhookconfigurations | grep -i identity
# Expect: pod-identity-webhook
```

**Step 2 — Identify pods missing IRSA mutation:**

```bash
# For each suspected pod
NS=<namespace>
POD=<name>

kubectl $KCONFIG -n $NS get pod $POD -o yaml | \
  grep -E "AWS_WEB_IDENTITY_TOKEN_FILE|AWS_ROLE_ARN|serviceAccountToken:|name: aws-iam-token" | head -10

# If MISSING all 4 lines → not mutated
```

**Step 3 — Delete the pod so it gets recreated (mutated this time):**

```bash
# For Deployments / StatefulSets / DaemonSets
kubectl $KCONFIG -n $NS delete pod $POD

# Watch the replacement get created with IRSA injected
sleep 15
kubectl $KCONFIG -n $NS get pod -l <label> -o yaml | \
  grep -E "AWS_WEB_IDENTITY_TOKEN_FILE|AWS_ROLE_ARN" | head -4
# Expect: env vars now present
```

For bare pods (no controller): need to recreate from manifest. Save the spec first, then `kubectl apply -f`.

### Verification

```bash
# 1. New pods have IRSA mutation
kubectl $KCONFIG -n <ns> get pod <new-pod> -o yaml | grep -A 2 "name: AWS_ROLE_ARN"
# Expect: value set

# 2. Pod actually uses IRSA (no IMDS fallback)
kubectl $KCONFIG -n <ns> logs <new-pod> --tail=50 | grep -iE "imds|169\.254\.169\.254"
# Expect: empty

# 3. AWS workload (e.g., RW S3) succeeds
kubectl $KCONFIG -n <ns> logs <new-pod> --tail=30 | grep -iE "s3|aws\.|sts"
# Look for successful operations
```

### Prevention

- **Track 5 NEW — Priority barrier**: PriorityClass + readiness gate so app workloads don't schedule before webhook is Ready (after cold start or restart)
- **Webhook High-Availability**: 2+ replicas of `pod-identity-webhook` with PodDisruptionBudget so it's never fully down
- **PromRule `PodIdentityWebhookDown`**: fires if webhook 0/n Ready for > 1 min — operations can know to delay deploys

### Related

- [[irsa-imds-fallback]] — downstream symptom when mutation is missing
- [[../06-incidents-timeline/2026-06-19-dns-irsa-rw-cascade]] — referenced but not the cause tonight (webhook was healthy; DNS was the real root)
- Memory: `[ssm_eks_data_fallback_progress]`

### Memory pointers

- `[ssm_eks_data_fallback_progress]` — OIDC chain
- `[Session state Jun 19]` — verified IRSA injection was correct tonight; problem was DNS, not webhook race
