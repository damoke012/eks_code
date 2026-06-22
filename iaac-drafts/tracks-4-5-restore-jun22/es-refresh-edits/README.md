# ExternalSecret refresh interval — 1h → 5m on critical paths

## Why

Critical-path secrets (license keys, IRSA-relayed cloud secrets, app credentials) currently refresh on a 1h interval. After a Secret rotation in AWS SM, on-prem won't pick up the change for up to an hour. Combined with Reloader (this PR series), 5m refresh means Secret rotation → app restart within 5 min worst-case.

## Critical paths (5m refresh)

These ExternalSecrets are bumped from `refreshInterval: 1h` → `5m`:

| Namespace | ExternalSecret | Why |
|---|---|---|
| risingwave | rw-root-credentials | Tim's RW root — rotate often |
| risingwave | rw-license-key | License updates need fast pickup |
| risingwave | rw-service-account-credentials | IRSA-relayed S3 creds |
| risingwave | rw-secret-store-private-key | RW pgcrypto key |
| risingwave | pg-credentials | Postgres mgmt creds |
| risingwave | risingwave-pg-credentials | RW-managed PG access |
| risingwave-2 | rw-root-credentials | Same as above for risingwave-2 |
| risingwave-2 | rw-license-key | |
| risingwave-2 | pg-credentials | |
| argocd | argocd-admin-credentials | Idris's track — keep fast |
| argocd | argocd-git-private-key | Git push token rotation |
| grafana | grafana-admin | Admin password rotation |
| enterprise | brands-api-azuread-secret | Brand API Azure AD secret |
| arc-runners | arc-runner-pat | GitHub PAT rotation |
| geoservices | geoenrichment-sync-handler-m-u | Atlas X.509 cert (cross-cluster, eventually 5m) |
| octopus | octopusworker | Octopus worker registration token |

## Non-critical paths (left at 1h)

Defaults stay 1h for low-impact ExternalSecrets (placeholder secrets, dev-only).

## Apply mechanism

sed-based mass-edit on `infrastructure/app-secrets/` + cross-cluster-app-secrets/.

```bash
# CAUTION: this changes ALL refreshInterval: 1h → 5m within these directories.
# If you want surgical control, edit per-file.
find infrastructure/app-secrets/ infrastructure/cross-cluster-app-secrets/ -name "*.yaml" \
  -exec sed -i 's/^  refreshInterval: 1h$/  refreshInterval: 5m/' {} +

# Verify diff scope
git diff --stat infrastructure/app-secrets/ infrastructure/cross-cluster-app-secrets/

# Sanity: should see ~16 files changed, 1 line each
```

If any file changed unexpectedly, revert with `git checkout <file>` before commit.
