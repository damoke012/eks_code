# ClusterSecretStore "default" Not Ready (DNS Cascade)

**Symptom:**
- `kubectl get clustersecretstore default` shows `READY=False`, `STATUS=NotReady`
- Events on the CSS reference: `failed to refresh cached credentials, failed to retrieve credentials, operation error STS: AssumeRoleWithWebIdentity, ... dial tcp: lookup sts.us-east-2.amazonaws.com: i/o timeout`
- All downstream ExternalSecrets in cluster show SecretSyncedError
- New ExternalSecrets created during the outage never get a Secret material

**Root cause:**
ClusterSecretStore "default" uses AWS auth (JWT/IRSA via `external-secrets` ServiceAccount in `external-secrets` namespace). To validate, the operator must:
1. Read the projected SA token
2. Call STS AssumeRoleWithWebIdentity (requires DNS resolution of `sts.us-east-2.amazonaws.com`)
3. Receive temp creds
4. Use those to validate access to Secrets Manager

If DNS is broken (or STS is unreachable due to network outage), step 2 fails → CSS marked NotReady → all dependent ExternalSecrets cascade into SecretSyncedError.

When DNS returns, CSS auto-recovers within its validation interval (~30s-5min).

**IaC coverage:** ✓ (CSS itself is codified; DNS dependency is implicit; recovery is automatic once DNS is restored)

**IaC location:**
- `iaac-talos-flux-platform/infrastructure/external-secrets/clustersecretstore.yaml` (or similar):
  ```yaml
  apiVersion: external-secrets.io/v1beta1
  kind: ClusterSecretStore
  metadata:
    name: default
  spec:
    provider:
      aws:
        service: SecretsManager
        region: us-east-2
        auth:
          jwt:
            serviceAccountRef:
              name: external-secrets
              namespace: external-secrets
  ```

### Resolution via IaC

For fresh clusters: CSS comes up validated within seconds of `external-secrets` pod readiness. No manual intervention.

For outage recovery: CSS auto-validates on next retry once DNS is restored. The downstream ExternalSecrets still need force-sync (see [[externalsecret-stale-sync]]) to clear their stale-error state.

### Manual resolution

**Step 1 — Verify CSS recovery after DNS restored:**

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

kubectl $KCONFIG get clustersecretstore default
# Expect: READY=True

# If still NotReady, check events
kubectl $KCONFIG describe clustersecretstore default | tail -30
```

**Step 2 — If CSS is wedged after DNS restored, restart external-secrets operator:**

```bash
kubectl $KCONFIG -n external-secrets rollout restart deploy external-secrets

# Wait + verify
sleep 30
kubectl $KCONFIG get clustersecretstore default
```

**Step 3 — Force-sync downstream ExternalSecrets:**

See [[externalsecret-stale-sync]] for the procedure.

### Verification

```bash
# 1. CSS Ready
kubectl $KCONFIG get clustersecretstore default
# Expect: READY=True

# 2. CSS validation succeeded recently (within last validation interval)
kubectl $KCONFIG describe clustersecretstore default | grep -A 3 "Last Transition Time\|Reason\|Status"
# Expect: Reason=Valid, Status=True

# 3. New ExternalSecret can sync
kubectl $KCONFIG -n external-secrets get externalsecret -A | head -10
# Expect: SecretSynced + READY=True for fresh ones
```

### Prevention

- **DNS health PromRule** (Track 4 NEW) — alerts on DNS failure within 3 min
- **CSS validity PromRule** (Track 5 NEW, draft): alerts if CSS not Ready > 5 min
- **Standby/secondary auth** for emergency: a backup ClusterSecretStore using static IAM access keys (not just IRSA) would survive STS outages. Trade-off: static keys are higher-risk operationally.

### Related

- [[../03-networking/cluster-dns-failure]] — primary upstream cause
- [[irsa-imds-fallback]] — same DNS-broken-then-fallback pattern
- [[externalsecret-stale-sync]] — downstream cleanup

### Memory pointers

- `[Session state Jun 19]` — CSS went from NotReady → Valid 4m after DNS fix (Last Transition Time: 2026-06-19T02:05:13Z)
- `[ssm_eks_data_fallback_progress]` — OIDC chain that CSS depends on
