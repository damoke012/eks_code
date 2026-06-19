# RisingWave Recovery After Secret Sync / DNS Restoration

**Symptom:**
- After resolving a DNS outage or ExternalSecret stuck-error condition, RW namespace pods are still failing:
  - `risingwave-meta-default-0` CrashLoopBackOff
  - `risingwave-compute-default-0` CrashLoopBackOff
  - `risingwave-frontend-*` CrashLoopBackOff
  - `risingwave-console` Init:CrashLoopBackOff
- Logs show various credential / network errors that USED to be true but are now resolved
- `kubectl get pod` shows pods running with high AGE — they booted during the outage and never recovered

**Root cause:**
RW pods are StatefulSet-managed; they don't auto-restart when their backing Secrets change. If a pod started during a DNS outage:
- It tried to fetch credentials → fell through to IMDS → timed out → began crashing
- Each restart re-reads stale env vars (the SAME Secret content from the failed sync window)
- Without explicit pod deletion, they CrashLoop forever even after dependencies recover

This is the [reloader pattern gap] — without `stakater/Reloader` or similar, pods don't notice Secret content changes.

**IaC coverage:** ❌ (manual procedure only; Reloader deployment planned in Track 5 NEW)

**IaC location:** N/A yet — Track 5 NEW plans to deploy stakater/Reloader

### Resolution via IaC (planned)

Once shipped: any Deployment / StatefulSet annotated `reloader.stakater.com/auto: "true"` automatically rolling-restarts when its referenced Secret or ConfigMap content changes. RW pods would auto-recover within ~30s of new credential availability.

### Manual resolution (current — proven 2026-06-19)

**Step 1 — Confirm DNS + CSS are healthy first:**

```bash
KCONFIG="--server=https://10.10.82.179:6443 --insecure-skip-tls-verify=true"

# DNS works
kubectl $KCONFIG run dns-test --image=busybox:1.36 --rm -it --restart=Never -- \
  nslookup istiod.istio-system.svc.cluster.local 2>&1 | tail -5
# Expect: address returned

# CSS Ready
kubectl $KCONFIG get clustersecretstore default
# Expect: READY=True

# ExternalSecrets synced
kubectl $KCONFIG -n risingwave get externalsecret
# Expect: all SecretSynced/Ready=True
```

If any of these fail, fix that first ([[../03-networking/cluster-dns-failure]], [[clustersecretstore-dns-dependency]], [[externalsecret-stale-sync]]).

**Step 2 — Delete RW pods to force fresh boot:**

```bash
# Delete the core RW pods — controllers respawn with current creds
kubectl $KCONFIG -n risingwave delete pod risingwave-meta-default-0
kubectl $KCONFIG -n risingwave delete pod risingwave-compute-default-0
kubectl $KCONFIG -n risingwave delete pod -l app=risingwave-frontend --ignore-not-found
kubectl $KCONFIG -n risingwave delete pod -l app=risingwave-compactor --ignore-not-found
kubectl $KCONFIG -n risingwave delete pod -l app=risingwave-console --ignore-not-found

# Wait for respawn cycle
sleep 60

# Check progress
kubectl $KCONFIG -n risingwave get pods -o wide
```

**Step 3 — If pods still fail, check istio-cni/ztunnel on RW nodes:**

If sandbox setup fails with `no ztunnel connection`, see [[../03-networking/istio-cni-ztunnel-stale]].

**Step 4 — Watch the meta pod's first 5 min of logs:**

```bash
kubectl $KCONFIG -n risingwave logs risingwave-meta-default-0 --tail=80 -f
# Ctrl-C after seeing "database marked as ready" / "database enter running"
```

Expected sequence:
1. `Starting meta node`
2. `INFO opendal::services s3 ... NotFound (permanent)` for `hummock/backup/manifest.json` (404 is OK — file doesn't exist yet)
3. DNS retry for `risingwave-compute-default-0.risingwave-compute:5688` (waiting for compute pod)
4. `resolve host addr socket_addr=10.244.x.x:5688` — compute pod found
5. `database enter running` ✓

### Verification

```bash
# 1. All 14 RW namespace pods Running
kubectl $KCONFIG -n risingwave get pods
# Expect: all READY=true (except occasional restart on compactor which is OK)

# 2. RW can serve traffic
nc -zv -w 5 10.10.82.27 32567   # NodePort for SQL frontend
# Expect: succeeded

# 3. psql can connect (from corp VPN)
psql -h rw2-sql.op-dev.usxpress.io -p 5432 -U <user> -c "SELECT 1"
# Expect: ?column? = 1

# 4. Hummock S3 access works (verify via meta logs)
kubectl $KCONFIG -n risingwave logs risingwave-meta-default-0 --tail=30 | grep -iE "imds|169\.254"
# Expect: empty (IRSA chain working)
```

### Cleanup

After successful recovery, dead duplicate pods may linger (CrashLoopBackOff replicas from old ReplicaSets):

```bash
# Find OLD stuck pods
kubectl $KCONFIG -n risingwave get pods | grep CrashLoop | awk '$5+0 > 20 { print $1 }'

# Delete them (their controllers won't recreate — they're orphan ReplicaSet members)
kubectl $KCONFIG -n risingwave delete pod <old-pod-1> <old-pod-2>
```

### Prevention

- **Track 5 NEW PR — deploy stakater/Reloader** — RW pods auto-restart when credentials change. No manual `delete pod` needed.
- **Track 5 NEW PR — tighten ExternalSecret refresh** to 5m. Less stale-credential window.
- Add RW restart procedure to on-call playbook with [[externalsecret-stale-sync]] cross-reference

### Related

- [[../03-networking/cluster-dns-failure]] — primary upstream cause
- [[clustersecretstore-dns-dependency]] — sister upstream
- [[externalsecret-stale-sync]] — must be resolved BEFORE RW recovery
- [[irsa-imds-fallback]] — symptom RW will show if IRSA chain broken
- [[../03-networking/istio-cni-ztunnel-stale]] — also blocks fresh RW pods from getting sandboxes
- [[../06-incidents-timeline/2026-06-19-dns-irsa-rw-cascade]] — tonight's full recovery sequence

### Memory pointers

- `[Session state Jun 19]` — proven sequence: DNS fix → CSS Valid → ES force-sync → istio-cni bounce → RW pod delete → 14 pods Running with IRSA verified
- `[Protect RW on op-usxpress-dev]` — safety guidance for invasive changes
