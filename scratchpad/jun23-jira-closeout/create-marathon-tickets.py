#!/usr/bin/env python3
"""Create JIRA tickets in INFRA project for the 2026-06-23 marathon closeout.

Creates 1 Epic + N child Tasks.
Most tasks are CLOSED (Done) with PR + resolution notes.
A few are TO DO (deferred) with clear next steps.

Idempotent-ish: detects existing by label `marathon-jun23` and skips creation.
"""
import json
import os
import sys
import urllib.request
import urllib.error
import base64

EMAIL = os.environ['ATLASSIAN_EMAIL']
TOKEN = os.environ['ATLASSIAN_TOKEN']
BASE = "https://usxpress.atlassian.net"
PROJECT = "INFRA"
SPRINT_ID = 4046  # UI Sprint 0 (active)
SPRINT_FIELD = "customfield_10010"
EPIC_LINK_FIELD = "customfield_10008"
DOKE = "712020:8d34bd84-b44f-4ec7-a839-478fedebc03d"

auth = base64.b64encode(f"{EMAIL}:{TOKEN}".encode()).decode()
HEADERS = {
    "Authorization": f"Basic {auth}",
    "Accept": "application/json",
    "Content-Type": "application/json",
}


def adf(text):
    """Convert plain text (with line breaks) into ADF document.

    Splits paragraphs on blank lines; preserves single newlines as soft breaks.
    Lines starting with '- ' become bullet list items.
    """
    blocks = []
    paragraphs = text.strip().split("\n\n")
    for para in paragraphs:
        lines = para.split("\n")
        # Bullet block detection
        if all(l.startswith("- ") or l.startswith("* ") for l in lines):
            items = []
            for l in lines:
                t = l[2:]
                items.append({
                    "type": "listItem",
                    "content": [{
                        "type": "paragraph",
                        "content": [{"type": "text", "text": t}],
                    }],
                })
            blocks.append({"type": "bulletList", "content": items})
        else:
            content = []
            for i, l in enumerate(lines):
                if i > 0:
                    content.append({"type": "hardBreak"})
                if l:
                    content.append({"type": "text", "text": l})
            blocks.append({"type": "paragraph", "content": content})
    return {"type": "doc", "version": 1, "content": blocks}


def api(method, path, body=None):
    req = urllib.request.Request(
        f"{BASE}{path}",
        data=json.dumps(body).encode() if body else None,
        method=method,
        headers=HEADERS,
    )
    try:
        with urllib.request.urlopen(req) as r:
            data = r.read().decode()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print(f"ERROR {e.code} {method} {path}\n  body: {body}", file=sys.stderr)
        raise


def search_label(label):
    """Find issues already tagged with the given label."""
    jql = f'project = INFRA AND labels = "{label}"'
    res = api("POST", "/rest/api/3/search/jql", {
        "jql": jql,
        "fields": ["summary", "labels", "status"],
        "maxResults": 50,
    })
    return res.get("issues", [])


def create_issue(summary, description, issuetype_id, labels, epic_key=None, transition_to_done=False):
    fields = {
        "project": {"key": PROJECT},
        "summary": summary,
        "description": adf(description),
        "issuetype": {"id": issuetype_id},
        "assignee": {"accountId": DOKE},
        "labels": labels,
    }
    # Epic gets Epic Name; Tasks linked via Epic Link
    if issuetype_id == "10006":  # Epic
        fields["customfield_10009"] = summary  # Epic Name (try common id)
    else:
        fields[SPRINT_FIELD] = SPRINT_ID
        if epic_key:
            fields[EPIC_LINK_FIELD] = epic_key
    try:
        res = api("POST", "/rest/api/3/issue", {"fields": fields})
    except urllib.error.HTTPError:
        # Retry without Epic Name (might not exist as customfield_10009 in this project)
        if "customfield_10009" in fields:
            del fields["customfield_10009"]
            res = api("POST", "/rest/api/3/issue", {"fields": fields})
        else:
            raise
    key = res["key"]
    print(f"  Created {key}: {summary}")
    if transition_to_done:
        transition(key, "Done")
    return key


def transition(key, target_name):
    res = api("GET", f"/rest/api/3/issue/{key}/transitions")
    target_id = None
    for t in res.get("transitions", []):
        if t["name"].lower() == target_name.lower():
            target_id = t["id"]
            break
    if not target_id:
        print(f"  WARN: no transition '{target_name}' on {key}; available: {[t['name'] for t in res.get('transitions',[])]}")
        return
    api("POST", f"/rest/api/3/issue/{key}/transitions", {"transition": {"id": target_id}})
    print(f"  Transitioned {key} -> {target_name}")


import urllib.parse

# === Idempotency check ===
existing = search_label("marathon-jun23")
if existing:
    print(f"Found {len(existing)} existing 'marathon-jun23' tickets, aborting to prevent duplicates:")
    for i in existing:
        print(f"  {i['key']}: {i['fields']['summary']}")
    sys.exit(0)

# === Create Epic first ===
print("Creating umbrella Epic...")
EPIC = create_issue(
    summary="On-prem op-usxpress-dev: restore-readiness + IaC closeout (jun23 marathon)",
    description="""Umbrella for the 2026-06-23 close-every-gap marathon on op-usxpress-dev. Goal: prove restore-readiness end-to-end (Velero PVC backup + restore, etcd → S3 snapshots), bring all platform components under IaC, and ship documentation so the QA cluster can be brought up tomorrow against this same pattern.

Outcomes proven:
- Velero PVC backup + restore tested end-to-end (test-restore-jun24 Completed, 20Gi ceph-block PVC restored)
- etcd snapshot → S3 operational (287MB validated snapshot, multi-container talosctl+aws-cli CronJob, hourly schedule)
- Prometheus + rw-2 prometheus-server on ceph-block (first prod workloads)
- rw-2 operator fully healthy with supplemental ClusterRole (9/9 resources)
- Talosconfig SM secret TF-managed via declarative ARN-based import (no value drift)
- External-DNS restart loop fixed (pod-identity-webhook re-mutation)
- Ceph mgr OOM resolved (memory 512Mi → 2Gi)
- Default branch flipped iaac-talos-flux-platform prod → op-dev

16 PRs merged across 4 repos. Child tasks below break the work into reviewable chunks each linked to its PRs.

External blockers:
- INFRA-1545 Postgres rw-2 ceph-block migration (needs Tim coord window)
- TF state cross-region replication (cloud-ops owns the bucket)
- INFRA-1535/1543 OnPremise Octopus space stand-up (needs admin token)""",
    issuetype_id="10006",
    labels=["marathon-jun23", "restore-readiness", "op-usxpress-dev"],
)

# === Create child Tasks ===
TASKS = [
    {
        "summary": "Velero: PVC backup + RESTORE proven end-to-end (op-usxpress-dev)",
        "description": """Stand up Velero with Kopia file-system backup, IRSA-backed S3 access, AWS_REGION env (Kopia-specific), and prove restore end-to-end.

PRs:
- variant-inc/iaac-talos #44 (TF IRSA role + S3 bucket velero-op-usxpress-dev)
- variant-inc/iaac-talos-flux-platform #55 (kubectl image bitnami → bitnamilegacy:1.32)
- variant-inc/iaac-talos-flux-platform #59 (Velero AWS_REGION env — initial attempt, caused helm rollback)
- variant-inc/iaac-talos-flux-platform #60 (Velero AWS_REGION env — remove duplicate, configuration block only)

Verified:
- test-backup-jun23-3 (prometheus ns) Phase: Completed, Kopia chunks 20+ MiB each
- test-restore-jun24 — 20Gi ceph-block PVC restored, 3 pods Running in restore-test ns
- daily-full schedule active 02:00 UTC, all-ns minus kube-system/flux-system, 14d retention
- BackupRepository Phase: Ready

Gotchas captured (in catalog):
- Velero chart renders BOTH configuration.extraEnvVars AND nodeAgent.extraEnvVars on node-agent DS — same env in both = duplicate-key SSA error → silent helm rollback. Use ONLY configuration.extraEnvVars.
- Kopia in node-agent makes its OWN STS call; BSL.config.region insufficient. Missing AWS_REGION shows up as sts..amazonaws.com (double-dot) in logs.""",
        "labels": ["marathon-jun23", "velero", "backup"],
        "done": True,
    },
    {
        "summary": "etcd snapshot → S3 operational (multi-container CronJob)",
        "description": """Hourly Talos etcd snapshot to S3 via Kubernetes CronJob. Multi-container pattern required because ghcr.io/siderolabs/talosctl:* is distroless (no shell).

PRs:
- variant-inc/iaac-talos #44 (TF IRSA role + S3 bucket etcd-snapshots-op-usxpress-dev)
- variant-inc/iaac-talos #48/#49 (TF talosconfig SM secret wrapper, declarative ARN import)
- variant-inc/iaac-talos-flux-platform #58 (pod-level seccompProfile RuntimeDefault for PSA restricted)
- variant-inc/iaac-talos-flux-platform #61 (multi-container restructure: talosctl initContainer + amazon/aws-cli main)
- variant-inc/iaac-talos-flux-platform #62 (memory bump — initContainer 256Mi was OOMKilled, bumped 1Gi + workdir off tmpfs)

Verified:
- 287.2 MiB snapshot at s3://etcd-snapshots-op-usxpress-dev/op-usxpress-dev/<TS>/snapshot.db (rev 59349168, 10994 keys)
- Schedule 17 * * * * (hourly), not suspended, running successfully
- ExternalSecret pulls talosconfig from AWS SM via IRSA — value untouched throughout TF wrapper migration

Gotchas captured:
- PSA enforce: restricted requires pod-level seccompProfile.type RuntimeDefault. Without it, Job retries forever silently.
- talosctl distroless image has /talosctl only; no /bin/sh. Need multi-container pattern with shared emptyDir for snapshot+upload.""",
        "labels": ["marathon-jun23", "etcd-backup", "backup"],
        "done": True,
    },
    {
        "summary": "TF: IRSA + S3 buckets for Velero + etcd-backup, talosconfig SM wrapper",
        "description": """Codify the IRSA roles, S3 buckets, and talosconfig AWS Secrets Manager wrapper into iaac-talos Terraform so a new cluster (e.g., QA) gets them as part of normal Octopus TfApply.

PRs:
- variant-inc/iaac-talos #44 — Initial: IAM roles + S3 buckets for Velero + etcd-backup, matching iaac-talos style (jsonencode, var.cluster_name, OIDC provider arn)
- variant-inc/iaac-talos #48 — Talosconfig SM secret wrapper (initial — broken import ID using secret NAME)
- variant-inc/iaac-talos #49 — Fix: use full ARN as SM secret import ID (AWS provider requires ARN with random suffix, not friendly name)

What's NOT in IaC (intentional):
- The talosconfig YAML VALUE is operator-seeded via aws secretsmanager put-secret-value (or initial create-secret); TF resource has lifecycle.ignore_changes = [secret_string]. Rationale: don't put x509 client cert+key into TF plan output or state.

Gotchas captured:
- TF import blocks must live in root module (deploy/terraform/talosconfig-secret-import.tf), NOT inside child modules. Use module.<name>.<resource> path in `to`.
- aws_secretsmanager_secret import requires full ARN (with suffix), not name. Wrong: id="op-usxpress-dev/talosconfig". Right: id="arn:aws:secretsmanager:...secret:op-usxpress-dev/talosconfig-jZx93J". Get via `aws secretsmanager describe-secret --query ARN`.""",
        "labels": ["marathon-jun23", "iac", "terraform"],
        "done": True,
    },
    {
        "summary": "Prometheus on ceph-block PVC (was emptyDir losing TSDB on restart)",
        "description": """Move Prometheus TSDB from emptyDir to ceph-block PVC (20Gi). First prod workload migrated to ceph-block. Prior state lost 4.9 GiB of TSDB data on every pod restart.

PR: variant-inc/iaac-talos-flux-platform #56

HelmRelease change: storageSpec.volumeClaimTemplate.spec.storageClassName: ceph-block, size: 20Gi.

Verified: Prometheus PVC bound to ceph-block, TSDB now durable across restarts.""",
        "labels": ["marathon-jun23", "rook-ceph", "observability"],
        "done": True,
    },
    {
        "summary": "rw-2 prometheus-server on ceph-block PVC (10Gi)",
        "description": """RW-2 components ship with their own embedded prometheus-server (chart sub-component). Migrate its PV from emptyDir to ceph-block 10Gi so RW metrics survive pod restart.

PR: variant-inc/iaac-risingwave-2 #17

HelmRelease change: prometheus.server.persistentVolume.storageClass: ceph-block, size: 10Gi.

Verified: rw-2 prometheus-server PVC bound to ceph-block (second prod workload on ceph-block).""",
        "labels": ["marathon-jun23", "rook-ceph", "risingwave", "observability"],
        "done": True,
    },
    {
        "summary": "rw-2 operator supplemental ClusterRole + binding (chart gap)",
        "description": """The risingwave-operator helm chart ships only a Role (namespace-scoped), but operator needs to LIST cluster-wide for configmaps, pods, statefulsets, deployments, services, secrets, jobs, and CRDs. Without supplemental ClusterRole, operator pod CrashLoops with permission errors and rw-2 instance never reconciles.

PRs:
- variant-inc/iaac-risingwave-2 #15 — initial supplemental ClusterRole (configmaps + pods)
- variant-inc/iaac-risingwave-2 #16 — extended (+statefulsets/deployments/services/secrets/jobs/CRDs)

Verified: rw-2 operator 1/1 Running 0 restarts, can-i list passes for all 9 cluster-scoped resources, rw-2 instance (compactor/compute/frontend/meta) Running for 7+h with 0 restarts.

Gotcha captured: risingwave-operator chart cluster RBAC is incomplete — supplemental ClusterRole + binding required PER cluster + PER non-default install namespace.""",
        "labels": ["marathon-jun23", "risingwave", "rbac"],
        "done": True,
    },
    {
        "summary": "Ceph mgr memory bump 512Mi → 2Gi (was OOMKilling 135x in 16h)",
        "description": """Default rook-ceph CephCluster mgr resources.limits.memory is 512Mi, undersized for any non-trivial cluster. Manifested as 135 OOMKill restarts in 16h, breaking ceph dashboard + manager-driven recovery operations.

PR: variant-inc/iaac-talos-flux-platform #54

Change: CephCluster.spec.resources.mgr.limits.memory: 2Gi (matching requests).

Verified: mgr 0 restarts post-merge, ceph -s healthy, ceph dashboard accessible.

Gotcha captured (in catalog): ceph mgr default 512Mi too small; bump to 2Gi for any prod-ish workload.""",
        "labels": ["marathon-jun23", "rook-ceph", "memory"],
        "done": True,
    },
    {
        "summary": "External-DNS IRSA re-mutation fix (pod-identity-webhook stale)",
        "description": """External-DNS pod was restart-looping (1323 restarts) because pod-identity-webhook hadn't injected AWS_ROLE_ARN env var on initial create — webhook re-mutation requires pod delete after IRSA SA annotation lands.

Fix: kubectl delete pod (one-time manual). Pod respawned with correct mutation, now Running 0 restarts.

NO IaC change required — pod-identity-webhook is event-driven on pod CREATE. Same pattern as rw-2 operator hit on jun22.

Follow-up sprint: Kyverno mutation policy that watches for orphaned IRSA SA + force pod-delete, OR move to native EKS pod-identity addon when on-prem gets a parallel solution.""",
        "labels": ["marathon-jun23", "irsa", "external-dns"],
        "done": True,
    },
    {
        "summary": "Default branch flip iaac-talos-flux-platform: prod → op-dev",
        "description": """The repo's default branch was `prod`, but op-usxpress-dev consumes `op-dev`. Default-branch matters for: PR base auto-suggest, GitHub UI landing page, gh CLI default, fork sync.

Flipped via repo Settings → Default Branch. No Flux change required (Flux GitRepository ref is explicit).""",
        "labels": ["marathon-jun23", "git-conventions"],
        "done": True,
    },
    {
        "summary": "Catalog ship: 6 entries + Flux bootstrap runbook to iaac-talos/deploy/docs/",
        "description": """Ship 6 catalog entries + 1 runbook to enterprise iaac-talos under deploy/docs/troubleshooting/. Catches the marathon's hard-won gotchas + the Flux bootstrap procedure.

Shipped (PR variant-inc/iaac-talos #45):
- 01-cluster-control-plane/talosctl-image-distroless.md
- 02-storage/cephcluster-mgr-oom-default.md
- 03-network-irsa/velero-kopia-aws-region-required.md
- 03-network-irsa/velero-chart-extra-env-duplicate.md
- 04-secrets-credentials/psa-restricted-seccomp-required.md
- 04-secrets-credentials/risingwave-operator-chart-cluster-binding.md
- runbooks/flux-bootstrap-from-scratch.md

Follow-up (this sprint, tonight): ship the remaining 30+ entries from wip/onprem-troubleshooting/ to the same path — combined with this PR's 6 they form a 37-entry catalog covering CP/storage/network/secrets/TF/incidents.""",
        "labels": ["marathon-jun23", "documentation"],
        "done": True,
    },
    {
        "summary": "Postgres rw-2: local-path → ceph-block migration (NEEDS TIM WINDOW)",
        "description": """RW-2's Postgres (data-postgres-postgresql-0 PVC) is bound to a 10Gi local-path PV pinned to talos-wk-op-dev-6. Node-local storage = single point of failure. Migrate to ceph-block now that it's operational + Velero backup is proven.

Runbook DRAFTED at iaac-drafts/jun23-closeout/postgres-migration-runbook.md.

Pre-reqs:
- Tim sign-off (rw-2 namespace, even though it's NOT his risingwave prod ns) — per memory rule protect-rw-onprem-workload
- ~30 min downtime window on rw-2
- Velero pre-backup as safety net (proven path)

Procedure: pg_dump → update HelmRelease storageClass to ceph-block → scale down → delete PVC → scale up → pg_restore → verify rw-2 components reconnect.

Rollback path: Velero restore from rw2-pre-postgres-migration backup.""",
        "labels": ["marathon-jun23", "rook-ceph", "risingwave", "postgres", "deferred"],
        "done": False,
    },
    {
        "summary": "READMEs across 6 on-prem repos covering new platform stack (jun23)",
        "description": """Sweep README documentation in the 6 on-prem enterprise repos to reflect what the jun23 marathon added. Drafts under iaac-drafts/jun23-closeout/readmes/<repo>/README.md ready for PR.

Target repos:
1. variant-inc/iaac-talos — TF: IRSA module additions (Velero + etcd-backup roles), talosconfig SM wrapper, declarative ARN import pattern, new-cluster bring-up notes
2. variant-inc/iaac-talos-flux-cluster — Kustomization layering (un-suspend pattern), default branch convention, PSA gotcha
3. variant-inc/iaac-talos-flux-platform — per-component sections: velero, etcd-backup, prometheus, rw-2 prometheus-server, rook-ceph mgr memory
4. variant-inc/iaac-risingwave-2 — supplemental ClusterRole pattern, ceph-block PVC migration, branch model
5. variant-inc/iaac-risingwave-onprem — Tim's repo conventions (read-only ack from our side)
6. variant-inc/iaac-octopus-onprem — OnPremise space + worker pattern (notes for INFRA-1535/1543 follow-up)

Drafted in codespace, shipped from WSL via PR per the existing PUSH-TO-ENTERPRISE pattern.""",
        "labels": ["marathon-jun23", "documentation", "iac"],
        "done": False,
    },
    {
        "summary": "TF state cross-region replication advisory (cloud-ops handoff)",
        "description": """The S3 bucket lazy-tf-state-65v583i6my68y6x9 (us-east-2, USX-Dev account) holds the cluster's TF state — single point of recovery for "rebuild cluster from scratch" scenarios. Currently NO cross-region replication. If bucket is deleted/corrupted/lost to regional AWS event, talosconfig + Talos machine config + IRSA OIDC discovery are unrecoverable except by rebuilding from manual machine config.

Advisory DRAFTED at iaac-drafts/jun23-closeout/tf-state-cross-region-advisory.md.

Asking cloud-ops to:
1. Add cross-region or cross-account replication
2. Confirm MFA-delete or guarded policy
3. Send back RPO/RTO for tfstate

NOT our team's bucket — cloud-ops owns. This ticket tracks our advisory submission, not implementation.""",
        "labels": ["marathon-jun23", "external-blocker", "cloud-ops-handoff", "tf-state"],
        "done": False,
    },
]

# === Create each task ===
print(f"\nCreating {len(TASKS)} child tasks under {EPIC}...")
created_keys = []
for t in TASKS:
    try:
        k = create_issue(
            summary=t["summary"],
            description=t["description"],
            issuetype_id="10002",
            labels=t["labels"],
            epic_key=EPIC,
            transition_to_done=t["done"],
        )
        created_keys.append((k, t["summary"], t["done"]))
    except Exception as e:
        print(f"  FAILED: {t['summary']}: {e}", file=sys.stderr)

print(f"\nSummary:")
print(f"  Epic: {EPIC}")
for k, s, done in created_keys:
    print(f"  {k} {'[Done]' if done else '[To Do]'}: {s}")
