# On-Prem Platform Troubleshooting Catalog

**Cluster:** op-usxpress-dev (Talos on-prem, 3 CPs + 7 workers)
**Maintained by:** Cloud Platform On-Prem (Doke)
**Target enterprise repo:** `variant-inc/iaac-talos` under `deploy/docs/troubleshooting/`

## What this is

Every issue we've encountered on the on-prem cluster, with:
- **Symptom** — what you'll see
- **Root cause** — why it happens
- **IaC coverage** — ✓ codified | ⚠ partial | ❌ manual only
- **Resolution via IaC** — how the IaC handles it (if applicable)
- **Manual resolution** — exact commands when IaC doesn't apply or isn't deployed
- **Prevention** — design + IaC choices that avoid recurrence
- **Related** — cross-links to other entries

## When to use this

- **Mid-incident**: jump to the topic folder matching the symptom
- **Post-mortem**: walk through related entries to capture full failure surface
- **Onboarding**: read top-down to learn the cluster's failure modes
- **Pre-deploy**: scan related entries to anticipate side effects

## How to read this

Issues are grouped by failure domain:

| Folder | Topics |
|---|---|
| [`01-cluster-control-plane/`](01-cluster-control-plane/) | CN-mismatch, CiliumNode drift, DNS death, CP IP shuffle, etcd quorum, kubelet PKI lockup |
| [`02-storage/`](02-storage/) | Rook-Ceph mon crashes, stuck finalizers, local-path helper pod, PVC binding, OSD spawning |
| [`03-networking/`](03-networking/) | Istio-CNI/ztunnel staleness, mesh exportTo scoping, externalDNS quirks, ambient HBONE NetworkPolicy, NodePort vs LB |
| [`04-secrets-credentials/`](04-secrets-credentials/) | ExternalSecret stale, IRSA → IMDS fallback, pod-identity-webhook race, ClusterSecretStore DNS dependency, Reloader patterns |
| [`05-terraform-octopus/`](05-terraform-octopus/) | compact() race, TfApply variable, branch base, TF import root module, Flux prune inventory, WSL corp-CA, S3 tag chars |
| [`06-incidents-timeline/`](06-incidents-timeline/) | Major cascades: 2026-06-17 CP OOM, 2026-06-18 Cilium-orphan cert, 2026-06-19 DNS+IRSA+RW |

## Standard entry format

```markdown
## <Issue Name>

**Symptom:** what you'll see — error messages, kubectl output, behavior
**Root cause:** mechanism — why this happens
**IaC coverage:** ✓ / ⚠ / ❌
**IaC location:** path/to/file.yaml in path/to/repo (if codified)

### Resolution via IaC
How the IaC handles or prevents this — what reconciles, what's auto-healed

### Manual resolution
```bash
# exact commands, paste-and-run
kubectl ...
talosctl ...
```

**Verification:**
```bash
# how to confirm fix took
```

### Prevention
What design / config / IaC change prevents recurrence

### Related
- [[issue-name-in-same-or-other-folder]]
- Memory: [[memory-pointer]]
```

## When IaC is not yet deployed

For issues marked ⚠ or ❌, the **Manual resolution** is the only available recovery. Until the IaC PR lands, the runbook is the source of truth for on-call.

## Updating this catalog

When you encounter a NEW failure mode:

1. Add an entry under the correct topic folder
2. Mark IaC coverage honestly (⚠ if WIP, ❌ if no PR yet)
3. Capture both the manual fix AND the design for IaC
4. Add a cross-link in [`06-incidents-timeline/`](06-incidents-timeline/) if it was an incident
5. Update this README's index if it's a new topic

## Skill integration

This catalog is loaded by the `/onprem-troubleshooting` Claude skill — see `.claude/skills/onprem-troubleshooting/SKILL.md`. When you describe a symptom to Claude, the skill surfaces the relevant entry.

## Pushing to enterprise

This WIP folder mirrors what ships to:

```
variant-inc/iaac-talos
  deploy/docs/troubleshooting/
    README.md
    01-cluster-control-plane/
    02-storage/
    03-networking/
    04-secrets-credentials/
    05-terraform-octopus/
    06-incidents-timeline/
```

PR command (run from WSL):

```bash
cd ~/work/iaac-talos
git checkout feature/op-usxpress-dev
git pull origin feature/op-usxpress-dev
git checkout -b docs/troubleshooting-catalog
mkdir -p deploy/docs/troubleshooting
cp -r /path/to/wip/onprem-troubleshooting/* deploy/docs/troubleshooting/
git add deploy/docs/troubleshooting/
git commit -m "docs: on-prem troubleshooting catalog (cluster + storage + networking + secrets + TF + incidents)"
git push -u origin docs/troubleshooting-catalog
gh pr create --base feature/op-usxpress-dev \
  --title "docs: troubleshooting catalog for on-prem cluster" \
  --body "Captures every failure mode encountered on op-usxpress-dev. Includes IaC coverage marker + manual resolution per issue."
```

## Quick index by symptom

| Symptom | Entry |
|---|---|
| `dial tcp: lookup ... i/o timeout` from in-cluster | [03-networking/cluster-dns-failure.md](03-networking/cluster-dns-failure.md) |
| `csr-: can only create a node CSR with CN=system:node:...` | [01-cluster-control-plane/kubelet-cn-mismatch.md](01-cluster-control-plane/kubelet-cn-mismatch.md) |
| `Failed to create pod sandbox: ... no ztunnel connection` | [03-networking/istio-cni-ztunnel-stale.md](03-networking/istio-cni-ztunnel-stale.md) |
| `Error: Invalid index ... var.worker_ips is list of string with 3 elements` | [05-terraform-octopus/compact-data-source-race.md](05-terraform-octopus/compact-data-source-race.md) |
| `error sending request for url (http://169.254.169.254/...)` | [04-secrets-credentials/irsa-imds-fallback.md](04-secrets-credentials/irsa-imds-fallback.md) |
| `ClusterSecretStore "default" is not ready` | [04-secrets-credentials/clustersecretstore-dns-dependency.md](04-secrets-credentials/clustersecretstore-dns-dependency.md) |
| `failed to inject barrier ... unconnected worker node` (RW) | [04-secrets-credentials/rw-recovery-after-secret-sync.md](04-secrets-credentials/rw-recovery-after-secret-sync.md) |
| Rook mons CrashLoopBackOff for hours | [02-storage/rook-mon-crashloop.md](02-storage/rook-mon-crashloop.md) |
| Rook OSDs CrashLoop `handle_auth_bad_method`, no `rook-ceph-osd-X-keyring` secrets | [02-storage/rook-osd-keyring-missing.md](02-storage/rook-osd-keyring-missing.md) |
| Rook operator restart → `failed to schedule canary pod(s)`, mon-endpoints CM empty | [02-storage/rook-operator-restart-state-loss.md](02-storage/rook-operator-restart-state-loss.md) |
| ConfigMap stuck with `deletionTimestamp` + finalizer | [02-storage/stuck-finalizer-removal.md](02-storage/stuck-finalizer-removal.md) |
| Pod stays Pending: `0/N nodes ... unschedulable` | [01-cluster-control-plane/cp-capacity-exhaustion.md](01-cluster-control-plane/cp-capacity-exhaustion.md) |
| ExternalSecret stuck SecretSyncedError after outage | [04-secrets-credentials/externalsecret-stale-sync.md](04-secrets-credentials/externalsecret-stale-sync.md) |

## Cross-reference inventory

- `/onprem-safety` skill — pre-deploy checks (capacity, etcd, RW baseline, talosconfig recovery)
- `/deploy-status` skill — read-only health check
- `wip/iac-sweep-jun18/INCIDENT-COVERAGE-MATRIX-2026-06-19.md` — 17-failure-mode IaC gap matrix
- `wip/iac-sweep-jun18/ROOK-CEPH-IMPLEMENTATION-2026-06-19.md` — Rook architecture + phases
- Memory: `MEMORY.md` index in `~/.claude/projects/-workspaces-eks-code/memory/`
