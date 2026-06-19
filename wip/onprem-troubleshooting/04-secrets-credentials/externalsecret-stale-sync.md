# ExternalSecret Stuck SecretSyncedError After Transient Outage

**Symptom:**
- `kubectl -n <ns> get externalsecret` shows `STATUS=SecretSyncedError`, `READY=False`, `LAST SYNC=<long time ago>`
- The actual Secret resource exists and may have stale credentials (last successful sync content)
- Pods using the Secret have stale env vars and may CrashLoop (e.g., wrong DB password)
- Events on the ExternalSecret reference the original outage cause (`ClusterSecretStore is not ready`, etc.)
- Even after the upstream cause is fixed, the ExternalSecret doesn't retry until its `refreshInterval` (typically 1h)

**Root cause:**
The external-secrets operator polls AWS Secrets Manager (or whatever backend) at the configured `refreshInterval`. If a sync attempt fails, it doesn't retry aggressively — it waits for the next scheduled refresh.

On a transient DNS outage of, say, 80 minutes (today's scenario), ExternalSecrets that synced just before the outage may be locked in error state for nearly another hour after the outage ends.

For RW credentials: the Secret content may still be valid (last good sync was 24 hours ago), but the ExternalSecret status says "error" which can confuse downstream consumers.

**IaC coverage:** ⚠ (refresh interval IS configurable but currently set to 1h on critical paths; force-sync mechanism is manual)

**IaC location:**
- `iaac-talos-flux-platform/infrastructure/risingwave-onprem/external-secret-*.yaml` (and similar for other workloads):
  ```yaml
  spec:
    refreshInterval: 1h     # ← bump down to 5m for critical paths (Track 5 NEW)
  ```
- Planned: tighten to `5m` on RW + ghostunnel TLS + RW operator paths
- Planned: deploy `stakater/Reloader` so pods auto-restart when their Secret content changes (Track 5 NEW)

### Resolution via IaC

Once shipped:
- 5m refresh on critical paths recovers from transient outages within 5 min instead of 1 hour
- Reloader detects Secret content changes (rolling annotation hash) and restarts dependent Deployments / StatefulSets automatically

### Manual resolution

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"
NS=<namespace>

# 1. Force-sync all ExternalSecrets in the namespace
for es in $(kubectl $KCONFIG -n $NS get externalsecret -o name); do
  kubectl $KCONFIG -n $NS annotate $es \
    force-sync=$(date +%s) --overwrite
done

# 2. Wait 30s for sync attempts
sleep 30

# 3. Verify they flip to SecretSynced
kubectl $KCONFIG -n $NS get externalsecret
# Expect: STATUS=SecretSynced, READY=True, LAST SYNC < 60s
```

If sync still fails: the upstream issue (DNS, ClusterSecretStore, AWS credentials) isn't fully resolved. See [[clustersecretstore-dns-dependency]] + [[irsa-imds-fallback]].

After force-sync succeeds, dependent pods STILL have stale env vars (no Reloader). Restart them:

```bash
# Restart all pods in the namespace that depend on the synced secrets
# (Easiest blanket approach — delete all pods, controllers recreate)
kubectl $KCONFIG -n $NS delete pod --all
```

Or for specific Deployments / StatefulSets:

```bash
kubectl $KCONFIG -n $NS rollout restart deploy <name>
kubectl $KCONFIG -n $NS rollout restart statefulset <name>
```

### Verification

```bash
# 1. All ExternalSecrets in the namespace are SecretSynced
kubectl $KCONFIG -n $NS get externalsecret
# Expect: all READY=True

# 2. The actual Secret resources have content
kubectl $KCONFIG -n $NS get secret <name> -o jsonpath='{.data}' | jq 'keys'
# Expect: expected keys present

# 3. Consuming pods boot with the new content
kubectl $KCONFIG -n $NS logs <pod> --tail=20 | grep -iE "error|fail|denied"
# Expect: clean startup, no credential errors
```

### Prevention

- **Track 5 NEW PR — refresh interval 1h → 5m** on critical ExternalSecrets (RW, ghostunnel TLS, etc.)
- **Track 5 NEW PR — deploy stakater/Reloader** — auto-restart Deployments / StatefulSets when their referenced Secret/ConfigMap content changes
- **DNS health PromRule** (Track 4 NEW) — catches the upstream cause faster
- **Critical-path indicator**: label ExternalSecrets that are critical with `priority: critical`, monitor those specifically

### Related

- [[clustersecretstore-dns-dependency]] — primary upstream cause
- [[irsa-imds-fallback]] — sister symptom
- [[rw-recovery-after-secret-sync]] — RW-specific cascade pattern
- [[../03-networking/cluster-dns-failure]] — root cause of today's stuck syncs

### Memory pointers

- `[Session state Jun 19]` — 7 RW ExternalSecrets stuck SecretSyncedError after DNS outage; force-sync resolved all 7
- `[Confirm before executing]` — pod restarts disrupt workloads; coordinate via [[../02-storage/rook-mon-crashloop]] if Rook is in flight
