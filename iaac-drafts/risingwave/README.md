# RisingWave IaC Artifacts

Drafted 2026-04-30 as part of Phase 1 closeout. These are ready-to-commit artifacts that
**Idris pushes to `iaac-talos-flux-platform/infrastructure/risingwave/`** (or future
`iaac-risingwave-onprem` when that repo lands), from his WSL.

The codespace can't push to `variant-inc/*` repos directly — auth issue, separate task.

## Files

| File | Where it goes | Purpose |
|---|---|---|
| `cluster-secrets-rw.yaml` | `iaac-risingwave-onprem/.github/workflows/onprem-cluster-secrets-rw.yaml` | GHA workflow to seed AWS SM secrets for postgres/root/license |
| `manifests-pg-externalsecret.yaml` | `iaac-talos-flux-platform/infrastructure/risingwave/pg-externalsecret.yaml` | ExternalSecret pulling Postgres metastore creds from SM |
| `manifests-rw-root-externalsecret-and-bootstrap-job.yaml` | `iaac-talos-flux-platform/infrastructure/risingwave/rw-root-bootstrap.yaml` | ExternalSecret + idempotent Job to set RW root password from SM |
| `manifests-dashboard-ext.yaml` | `iaac-talos-flux-platform/infrastructure/risingwave/dashboard-ext.yaml` | NodePort Service for RW Dashboard UI (sibling of frontend-ext) |
| `network-team-ask.md` | (not committed — reference doc to send to network team) | Formal ask for BGP / static routes |
| `wsl-bootstrap.sh` | `variant-inc/dev-environment-bootstrap` (future repo) | First-time setup script for engineer's WSL — corp CA + dev tools |

## Order of application

1. **Seed AWS SM** first — either via the GHA workflow (after IAM role + repo secrets are set up)
   or one-time CLI:
   ```bash
   aws secretsmanager create-secret \
     --name op-usxpress-dev/risingwave/postgres \
     --secret-string '{"username":"risingwave","password":"<gen>","postgres-password":"<gen>"}' \
     --region us-east-2 --profile usx-dev
   aws secretsmanager create-secret \
     --name op-usxpress-dev/risingwave/root \
     --secret-string '{"password":"<gen>"}' \
     --region us-east-2 --profile usx-dev
   ```

2. **Apply ExternalSecrets** — Flux picks them up after they're committed:
   - `pg-externalsecret.yaml`
   - the ExternalSecret in `rw-root-externalsecret-and-bootstrap-job.yaml`

3. **Verify k8s Secrets materialized**:
   ```bash
   kubectl get secret -n risingwave pg-credentials rw-root-credentials
   ```

4. **Apply the Bootstrap Job** — runs `ALTER USER root` from SM-sourced password.
   Idempotent; runs as no-op if already correct.

5. **Apply the Dashboard NodePort Service** — exposes the UI to VPN clients on `:32569`.

6. **Update kustomization.yaml** in the same directory to include the new resources:
   ```yaml
   resources:
     - frontend-lb.yaml
     - pg-externalsecret.yaml
     - rw-root-bootstrap.yaml
     - dashboard-ext.yaml
   ```

## Verified-correct values (after live deployment 2026-05-01)

The manifests are now updated to match what's actually in the cluster:

- **API version**: `external-secrets.io/v1` (NOT `v1beta1` — the cluster only has v1)
- **ClusterSecretStore name**: `default` (NOT `aws-secretsmanager` — the AWS SM-backed store on this cluster is `default`)
- **Target Secret name for Postgres**: `risingwave-pg-credentials` (matches RW CR's reference, NOT `pg-credentials`)
- **Target Secret name for RW root**: `rw-root-credentials` (new Secret, no transition needed)
- **creationPolicy**: `Owner` (after Merge transition for pg, fresh for root)

## Status of each artifact

| File | Deployed? | Notes |
|---|---|---|
| `manifests-pg-externalsecret.yaml` | ✅ DEPLOYED 2026-05-01 | Merge → Owner transition successful. Self-heal verified. |
| `manifests-rw-root-externalsecret-and-bootstrap-job.yaml` (ExternalSecret part) | ✅ DEPLOYED 2026-05-01 | Owner from start. Secret materialized correctly. |
| `manifests-rw-root-externalsecret-and-bootstrap-job.yaml` (Job part) | ❌ NOT deployed | Rotation flow needs design. Current state matches anyway. |
| `manifests-dashboard-ext.yaml` | ❌ NOT deployed | Pending. NodePort for Dashboard UI. |
| `cluster-secrets-rw.yaml` | ❌ NOT used (manual SM seeding 2026-05-01 instead) | Use post-PTO when iaac-risingwave-onprem repo + IAM role exist. |

## Caveats and known gaps

- **Bootstrap Job rotation gap**: the Job sets root password from SM on first run. If
  you rotate the SM value later, RW still has the OLD password — the Job can't authenticate
  to set the new one. Mitigation: rotate via psql first using the OLD password (or unset
  via Postgres direct access), then update SM. Future improvement: rotate workflow that
  takes both old + new password.
- **License key path** is documented but not auto-seeded — Tim coordinates with Zach (RW
  Labs) for the premium key, then manual `aws secretsmanager put-secret-value` to seed
  `op-usxpress-dev/risingwave/license`.
- **WSL bootstrap script** assumes a USXpress-published internal endpoint for the corp CA.
  That endpoint doesn't exist yet — Service Desk ask is open. Until then the script falls
  back to the engineer's Windows trust store export.

## Reference docs

- [risingwave_phase1_closeout_and_tim_handoff.md](../risingwave_phase1_closeout_and_tim_handoff.md) — master synthesis
- [risingwave_repo_structure_guide.md](../risingwave_repo_structure_guide.md) — full repo blueprint
- [risingwave_onprem_platform.md](../risingwave_onprem_platform.md) — comprehensive platform reference
