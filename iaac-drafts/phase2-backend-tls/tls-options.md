# Phase 2 TLS — Option A (native RW) vs Option B (ghostunnel sidecar)

The cert-manager Certificate is identical in both. The question is **where TLS terminates** in the RW-2 pod.

## Option A — Native RisingWave frontend TLS

RisingWave's `frontend` component supports TLS on port 4567 via CR config (`spec.frontend.ssl` block) on recent operator versions. If our cluster runs that version, this is the clean option.

**Required CR patch** (`rw-cr-tls-patch-native.yaml`):

```yaml
spec:
  frontend:
    sslConfig:
      enabled: true
      secretName: rw2-sql-tls
      # mountPath is fixed by the operator; the chart maps it.
```

**Pros**
- One config block, no extra container
- Mesh-internal RW components keep speaking the operator's wire format (no change required)
- Cert reload happens via operator restart on Secret rotation

**Cons**
- Requires operator version with sslConfig support. Verify version on WSL:
  ```bash
  kubectl get risingwave -n risingwave-2 -o jsonpath='{.items[0].spec.image}'
  # e.g. risingwavelabs/risingwave:v2.0.0
  ```
- Older versions reject sslConfig silently — would need bump first

## Option B — ghostunnel sidecar

A tiny TLS-terminator container that listens on port 4567 with TLS and proxies to the RW frontend on port 4566 internally.

**ghostunnel-sidecar.yaml**: a sidecar in the frontend pod template (or a separate Deployment + Service). Reads `/tls/tls.crt` + `/tls/tls.key` from the cert-manager-issued Secret.

**Pros**
- Works regardless of RW operator version
- Lower-risk to roll back — delete sidecar, fall back to existing port
- ghostunnel is well-trodden in K8s (lyft, Square production)

**Cons**
- Extra container per pod
- Two listeners on the same Service port number — need a port rename / Service split
- More moving parts to monitor

## Decision criteria

```
IF risingwave operator version >= [version with sslConfig support]:
    use Option A
ELSE IF operator can be bumped safely:
    bump operator, then Option A
ELSE:
    Option B
```

The "version with sslConfig support" needs a quick check of the RW operator changelog on WSL before committing. Tentative: any version >= v0.1.36 supports it (matches the version Idris pinned in PR #7, so we're likely already there) — confirm before merging.

## Backward-compat for internal callers

Phase 1 gateway routes `rw2-sql.op-dev.usxpress.io:4567` to `risingwave-frontend.risingwave-2.svc:4567`. Two cases:

| Internal caller | Today | After Phase 2 |
|---|---|---|
| RW operator → frontend | plain 4566 (operator's port) | unchanged |
| Mesh-internal clients hitting `risingwave-frontend.risingwave-2.svc:4567` directly | plain | MUST switch to TLS or go through the gateway |

Tim's pipelines (in `risingwave` ns) don't hit our `risingwave-2` directly, so no spillover there. Verify with `kubectl get netpol -n risingwave-2` + a quick `grep` of any chart values that reference `risingwave-frontend.risingwave-2.svc.cluster.local`.
