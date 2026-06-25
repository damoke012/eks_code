#!/usr/bin/env python3
"""
Publish the QA stand-up + production-readiness Confluence page +
file the parent epic + 22 sub-tickets with story points.
"""
import json, urllib.request, urllib.error, base64
from pathlib import Path

EMAIL = "doke@usxpress.com"
TOKEN = ""
for ln in Path("/workspaces/eks_code/scripts/push-to-confluence.sh").read_text().splitlines():
    if ln.startswith("CONFLUENCE_TOKEN="):
        TOKEN = ln.split("=", 1)[1].strip().strip('"').strip("'")
        break
assert TOKEN
DOKE_ACCOUNT_ID = "712020:8d34bd84-b44f-4ec7-a839-478fedebc03d"
CONF_URL = "https://usxpress.atlassian.net/wiki"
JIRA_BASE = "https://usxpress.atlassian.net"
SPACE = "UI"
TALOS_PARENT_ID = "3320938539"
auth = base64.b64encode(f"{EMAIL}:{TOKEN}".encode()).decode()
H_JSON = {"Authorization": f"Basic {auth}", "Content-Type": "application/json", "Accept": "application/json"}
STORY_POINTS_FIELD = "customfield_10028"


def adf(text):
    blocks = []
    for para in text.strip().split("\n\n"):
        lines = para.split("\n")
        if all(l.startswith("- ") for l in lines):
            items = [{"type": "listItem", "content": [{"type": "paragraph", "content": [{"type": "text", "text": l[2:]}]}]} for l in lines]
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


def api(url, method, body=None, headers=H_JSON):
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body else None, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        print(f"  HTTP {e.code} {method} {url}: {e.read().decode()[:600]}")
        raise


# ============ 1. Publish the Confluence page ============

body_html = Path("/workspaces/eks_code/iaac-drafts/jun25-qa-standup-design/confluence-qa-standup-design.html").read_text()

print("Publishing Confluence page...")
res = api(
    f"{CONF_URL}/rest/api/content",
    "POST",
    {
        "type": "page",
        "title": "QA cluster stand-up — production-readiness design (op-usxpress-qa)",
        "space": {"key": SPACE},
        "ancestors": [{"id": TALOS_PARENT_ID}],
        "body": {"storage": {"value": body_html, "representation": "storage"}},
    },
)
PAGE_ID = res["id"]
print(f"  Page id: {PAGE_ID}")
print(f"  URL: {CONF_URL}/spaces/{SPACE}/pages/{PAGE_ID}")


# ============ 2. File the parent epic ============

epic_description = f"""Umbrella epic for standing up op-usxpress-qa on-prem Talos cluster with production-readiness hardening. Design documented in Confluence page id {PAGE_ID} ({CONF_URL}/spaces/{SPACE}/pages/{PAGE_ID}).

Scope: this is not a relaxed copy of Dev. QA is the first cluster built to the standard Prod will be held to. Each child ticket addresses one section of the design document; all together they constitute production-readiness.

Phases (each phase gates the next):
1. Foundation -- AWS account boundary, Secrets Manager paths, ECR access, Route 53 zone, TF state bucket with CRR
2. Cluster -- Talos cluster provisioned with three node pools (system / platform / application), labels, taints, vSphere anti-affinity
3. Platform -- Flux bootstrap, identity management, log management end-to-end, cert-manager, ESO, Velero, Rook-Ceph, monitoring, Istio, Kyverno
4. Application + governance -- platform-app-expose generalised, first application onboarded, path-to-Production gates enforced, full cluster loss restore drill held

Acceptance for the epic: every section of the linked Confluence page is implemented, the 13 acceptance criteria in Section 14 are all met, and QA is declared production-ready meaning Prod stand-up can proceed from this baseline."""

print("\nFiling parent epic...")
epic_res = api(
    f"{JIRA_BASE}/rest/api/3/issue",
    "POST",
    {
        "fields": {
            "project": {"key": "INFRA"},
            "summary": "Stand up op-usxpress-qa cluster + production-readiness hardening",
            "issuetype": {"name": "Epic"},
            "labels": ["onprem", "qa", "production-readiness", "op-usxpress-qa"],
            "assignee": {"accountId": DOKE_ACCOUNT_ID},
            "description": adf(epic_description),
        }
    },
)
EPIC_KEY = epic_res["key"]
print(f"  Epic: {EPIC_KEY}")


# ============ 3. File the 22 sub-tickets ============

tickets = [
    # Phase 1 -- Foundation
    {
        "summary": "QA Foundation: AWS account boundary + Secrets Manager path + Route 53 zone",
        "story_points": 5,
        "phase": "Phase 1 -- Foundation",
        "description": """Establish the off-cluster resource boundary for op-usxpress-qa.

Acceptance criteria:
- Route 53 hosted zone op-qa.usxpress.io created in USX-QA (account 527101283767); NS delegation from corporate DNS verified
- AWS Secrets Manager path prefix op-usxpress-qa/ exists; placeholder secrets seeded for cert-manager, ESO, Velero
- IRSA pattern verified: a test IAM role with condition op-usxpress-qa/* successfully reads its placeholder secret; same role denies access to op-usxpress-dev/*

Design reference: Section 1 of the QA stand-up Confluence page.""",
    },
    {
        "summary": "QA Foundation: Terraform state bucket + S3 CRR + DynamoDB lock",
        "story_points": 5,
        "phase": "Phase 1 -- Foundation",
        "description": """Provision the on-prem Talos cluster TF state bucket for QA in USX-QA, with CRR to us-west-2 from day one.

Acceptance criteria:
- Bucket lazy-tf-state-<suffix> created in USX-QA us-east-2
- S3 CRR live to a sibling bucket in us-west-2 with the SSE-KMS triple-gotcha pattern (kms:Decrypt on source key, sse_kms_encrypted_objects opt-in, destination CMK with replica_kms_key_id)
- DynamoDB lock table provisioned
- Terraform remote backend configured pointing at the new bucket; state-of-state lives in the same bucket and replicates with everything else

Design reference: Section 1 of the QA stand-up Confluence page; reuses pattern from INFRA-1557.""",
    },
    {
        "summary": "QA Foundation: ECR access pattern + image promotion gate",
        "story_points": 5,
        "phase": "Phase 1 -- Foundation",
        "description": """Wire the QA cluster's ECR access pattern + define how images are promoted Dev -> QA.

Acceptance criteria:
- ECR pull credentials live on QA via the existing cross-account pull pattern (the same one Dev uses against the 064859874041 DevOps ECR)
- Image promotion mechanism: an image SHA pulled by Dev is re-tagged in ECR (no rebuild) when promoted to QA
- Promotion gate documented: only signed images are deployable to QA application namespaces (signing pattern delivered in the cosign ticket)

Design reference: Section 10 of the QA stand-up Confluence page.""",
    },
    # Phase 2 -- Cluster
    {
        "summary": "QA Cluster: Talos cluster provisioning (VMs, networking, machine config)",
        "story_points": 13,
        "phase": "Phase 2 -- Cluster",
        "description": """Provision the op-usxpress-qa Talos cluster on vSphere.

Acceptance criteria:
- 3 control plane nodes at 4 vCPU / 16 GB RAM / 50 GB boot + 50 GB etcd disk
- Worker pools sized per Section 2 of the design: 2 system, 3 platform, 5 application
- VIP allocated and reachable (corp DNS + corporate firewall ACLs updated)
- Talos cluster bootstrap succeeds, API server reachable
- Machine configuration in iaac-talos repo on feature/op-usxpress-qa branch (matching the Dev pattern)
- talosconfig stored in AWS SM op-usxpress-qa/platform/talosconfig with the same TF-managed ARN-import pattern Dev uses

Design reference: Section 2 of the QA stand-up Confluence page.""",
    },
    {
        "summary": "QA Cluster: Three node pool architecture (system / platform / application) with labels and taints",
        "story_points": 8,
        "phase": "Phase 2 -- Cluster",
        "description": """Implement the node pool isolation from Section 3 of the design.

Acceptance criteria:
- Talos machine config applies kubelet node-labels at provisioning time: node.cloud-platform.io/pool=system|platform|app
- System pool taint: node-role.cloud-platform.io/system:NoSchedule
- Platform pool taint: node-role.cloud-platform.io/platform:NoSchedule
- Application pool untainted (default scheduling target)
- Every platform Flux HelmRelease updated to include the platform pool nodeSelector and toleration; the same chart values apply to Dev (retrofit) and QA from day one
- A test pod with no scheduling hints lands on the application pool
- A test pod with platform tolerations lands on the platform pool
- kube-system DaemonSets present on every node (system pool inclusive)

Design reference: Section 3 of the QA stand-up Confluence page.""",
    },
    {
        "summary": "QA Cluster: vSphere fault-domain audit + DRS anti-affinity",
        "story_points": 5,
        "phase": "Phase 2 -- Cluster",
        "description": """Audit and enforce ESXi host spread for the QA worker pools.

Acceptance criteria:
- Current vSphere host topology documented: minimum 3 ESXi hosts identified for QA placement
- DRS anti-affinity rule per node pool: system pool members spread across >=3 ESXi hosts; same for platform and application pools
- Host-to-VM map captured in the cluster runbook
- A planned vMotion of one node verifies DRS places it on a host that does not already host another pool member

Design reference: Section 8 of the QA stand-up Confluence page.""",
    },
    # Phase 3 -- Platform
    {
        "summary": "QA Platform: Flux bootstrap + cluster + platform Kustomizations",
        "story_points": 5,
        "phase": "Phase 3 -- Platform",
        "description": """Bootstrap Flux on QA and wire the Kustomizations.

Acceptance criteria:
- Flux bootstrap on QA pointing at iaac-talos-flux-cluster master/clusters/op-usxpress-qa/ and iaac-talos-flux-platform op-qa branch
- New branch op-qa created in iaac-talos-flux-platform; Kustomizations applied
- flux-system Kustomization Ready
- All platform Kustomizations target the platform node pool (nodeSelector + toleration)

Design reference: Section 13 of the QA stand-up Confluence page.""",
    },
    {
        "summary": "QA Platform: identity management (admin certificates + IRSA roles)",
        "story_points": 8,
        "phase": "Phase 3 -- Platform",
        "description": """Provision the identity surfaces for QA per Section 4 of the design.

Acceptance criteria:
- Administrator X.509 certificates issued for at least Doke, Idris, Tim Preble (namespace-scoped to risingwave only); break-glass certificate in 1Password
- ClusterRoleBindings mapped to certificate subjects; kubectl auth whoami verifies each
- IRSA roles provisioned for at least: velero-backup, etcd-backup, external-secrets, external-dns, cert-manager. Naming convention op-usxpress-qa-<workload>-<purpose>
- A cross-environment access attempt from a QA IRSA role against Dev resources is denied (verified via aws sts decode-authorization-message)

Design reference: Section 4 of the QA stand-up Confluence page; the cluster-admin SSO half is parented under INFRA-1559.""",
    },
    {
        "summary": "QA Platform: log management end-to-end (Loki + fluent-bit + audit policy + S3 cold storage)",
        "story_points": 13,
        "phase": "Phase 3 -- Platform",
        "description": """Stand up the canonical log management pipeline from Section 5 of the design.

Acceptance criteria:
- Loki deployed on the platform pool with S3 backend in USX-QA; 2 ingester replicas; distributor
- fluent-bit DaemonSet on every node (including system and platform pools) shipping stdout/stderr to Loki
- Talos audit policy enabled: RequestResponse for secrets/tokenreviews/clusterrolebindings/pods-exec/pods-portforward/networkpolicies; Metadata otherwise; None for system controller routine reads
- Audit log on each CP node shipped via fluent-bit to Loki with a dedicated stream tag
- Grafana Loki datasource provisioned; engineers query via Grafana Explore
- A kubectl exec on QA produces an audit event visible in Loki within 30 seconds; the event includes requester identity
- Retention enforced: 30 days hot in Loki for audit, 7 days for app, 14 days for platform; S3 lifecycle to cold for the documented periods (1 year audit, 30 days app, 90 days platform)
- PrometheusRule alert on sudden audit log volume drop or spike

Design reference: Section 5 + Section 6 of the QA stand-up Confluence page.""",
    },
    {
        "summary": "QA Platform: cert-manager + per-env wildcard cert for *.op-qa.usxpress.io",
        "story_points": 3,
        "phase": "Phase 3 -- Platform",
        "description": """Provision cert-manager on QA with the per-team cert pattern.

Acceptance criteria:
- cert-manager deployed on the platform pool
- Wildcard certificate for *.op-qa.usxpress.io issued via Let's Encrypt DNS-01 (using the QA External-DNS IRSA role for the challenge)
- ClusterIssuer wired against AWS Route 53 zone op-qa.usxpress.io
- Per-team Certificate resources follow the documented pattern (onprem-per-team-cert-pattern-may28)
- Renewal verified during the DR drill (auto-renew at 60 days)

Design reference: Section 11 of the QA stand-up Confluence page.""",
    },
    {
        "summary": "QA Platform: External-Secrets Operator + ClusterSecretStore",
        "story_points": 3,
        "phase": "Phase 3 -- Platform",
        "description": """Wire ESO to read from the QA AWS Secrets Manager path prefix.

Acceptance criteria:
- ESO deployed on the platform pool
- ClusterSecretStore aws-sm with IRSA role op-usxpress-qa-external-secrets restricted to op-usxpress-qa/* path
- Test ExternalSecret reads a placeholder value and creates the k8s Secret
- Cross-environment access denied (a test ExternalSecret pointing at op-usxpress-dev/* fails with AccessDenied)

Design reference: Section 1 + Section 4.2 of the QA stand-up Confluence page.""",
    },
    {
        "summary": "QA Platform: Velero + DR pre/post checks + first PVC restore drill",
        "story_points": 5,
        "phase": "Phase 3 -- Platform",
        "description": """Provision Velero on QA + execute the first restore drill.

Acceptance criteria:
- Velero deployed on the platform pool; Kopia + AWS_REGION env per the documented gotchas (no duplicate env blocks, AWS_REGION required)
- Backup target: S3 bucket in USX-QA with CRR to us-west-2
- Daily backup schedule for all PVCs
- Restore drill: a non-trivial PVC is deleted, restored from the most recent backup, verified that the pod returns to Ready and data is intact
- restore-test ns cleaned up after the drill (memory pointer: feedback-velero-restore-test-ns-servicemonitor-leak)

Design reference: Section 7 of the QA stand-up Confluence page.""",
    },
    {
        "summary": "QA Platform: etcd-backup CronJob to S3",
        "story_points": 3,
        "phase": "Phase 3 -- Platform",
        "description": """Provision daily etcd snapshots from QA control plane to S3.

Acceptance criteria:
- Multi-container CronJob pattern (talosctl image is distroless, requires the aws-cli sidecar pattern -- see memory feedback_talosctl_image_distroless)
- IRSA role op-usxpress-qa-etcd-backup writes to a dedicated S3 path in USX-QA
- First snapshot is at least 100 MB (sanity check on real cluster state) and uploaded successfully
- CRR replicates the snapshot to us-west-2 within 60 seconds

Design reference: Section 7 of the QA stand-up Confluence page.""",
    },
    {
        "summary": "QA Platform: Rook-Ceph with OSD placement on the application pool",
        "story_points": 8,
        "phase": "Phase 3 -- Platform",
        "description": """Deploy Rook-Ceph with OSDs constrained to the application pool nodes that hold the secondary data disk.

Acceptance criteria:
- Rook operator on the platform pool
- CephCluster spec placement.osd selects nodes with node.cloud-platform.io/pool=app AND a label confirming the secondary data disk is present
- OSDs spread across 3+ ESXi hosts (the anti-affinity from Section 8)
- Ceph mgr memory 2Gi (per memory: feedback-ceph-mgr-memory-default-too-small)
- ceph-block and ceph-filesystem StorageClasses created; tested by a sample PVC
- CSI plugin tolerations: [] and explicit CP-exclusion node affinity (per /onprem-safety Rule 1)

Design reference: Section 3 + Section 2 of the QA stand-up Confluence page.""",
    },
    {
        "summary": "QA Platform: Prometheus + Grafana + AAD SSO + baseline dashboard",
        "story_points": 8,
        "phase": "Phase 3 -- Platform",
        "description": """Stand up the QA monitoring stack mirroring Dev's Phase 0 architecture (ADR-001).

Acceptance criteria:
- kube-prometheus-stack chart deployed on platform pool; Prometheus 4 GiB memory limit (per memory: feedback-kube-prometheus-stack-memory-4gi); ceph-block PVC 20Gi
- node-exporter hostNetwork: false during the period legacy charts exist (per memory: feedback-node-exporter-hostnetwork-false-in-mixed-charts)
- serviceMonitorSelectorNilUsesHelmValues: false for cluster-wide auto-discovery
- Grafana on platform pool; AAD OIDC SSO using the shared Dev+QA App Registration (parent under INFRA-1559); RBAC mapping to AAD groups cloud-platform-admins/engineers/app-team-readers
- Grafana wildcard cert from cert-manager; ingress at grafana.op-qa.usxpress.io via Istio Gateway
- Baseline dashboard "Kubernetes Cluster Overview" renders live cluster data (Nodes, Pods, CPU%, Memory%, per-node)
- Datasource UID pinned (per memory: feedback-grafana-datasource-uid-reprovision)

Design reference: Section 4.3 + Section 11 of the QA stand-up Confluence page; mirrors ADR-001 Decision 1 and 2.""",
    },
    {
        "summary": "QA Platform: Istio Gateway + DNS Gateway record for op-qa.usxpress.io",
        "story_points": 5,
        "phase": "Phase 3 -- Platform",
        "description": """Provision the Istio Gateway and External-DNS Gateway record for the QA subdomain.

Acceptance criteria:
- Istio control plane on the platform pool
- Istio ingress gateway DaemonSet with hostPort exposure (matching the proven Dev pattern -- onprem-http-dns-complete-may19)
- Gateway resource for *.op-qa.usxpress.io with the wildcard TLS cert from cert-manager
- External-DNS writes the Route 53 A record for the Gateway
- A test VirtualService routes traffic to a sample backend over HTTPS with the LE-issued wildcard

Design reference: Section 11 + Section 12 of the QA stand-up Confluence page.""",
    },
    # Phase 4 -- Application + governance
    {
        "summary": "QA Governance: Pod Security Admission tier policy enforcement",
        "story_points": 5,
        "phase": "Phase 4 -- Application + governance",
        "description": """Enforce per-namespace PSA tiers per Section 9 of the design.

Acceptance criteria:
- Namespace labels applied: kube-system = privileged; platform namespaces (cert-manager, eso, velero, rook-ceph, monitoring, istio-system, kyverno, reloader) = baseline; application namespaces (risingwave, brands-api, attrition-api, future tenants) = restricted
- A test pod attempting privileged escalation in an application namespace is rejected at admission with a clear error
- Verify seccompProfile RuntimeDefault is required on application namespaces (per memory: feedback-psa-restricted-seccomp-required)

Design reference: Section 9 of the QA stand-up Confluence page.""",
    },
    {
        "summary": "QA Governance: Kyverno policy baseline + image signing with cosign",
        "story_points": 8,
        "phase": "Phase 4 -- Application + governance",
        "description": """Layer Kyverno policies on top of PSA per Section 9 + Section 10.

Acceptance criteria:
- Kyverno controller on the platform pool
- ClusterPolicy: image signature verification (cosign) on application namespaces; trusted keys stored in AWS KMS; key references in the policy
- ClusterPolicy: required label set on all application namespace resources (app.kubernetes.io/name, app.kubernetes.io/instance, app.kubernetes.io/managed-by)
- ClusterPolicy: NetworkPolicy required in every application namespace; missing NP triggers a warning after a 7-day grace period, then blocks
- ClusterPolicy: approved registry list (064859874041.dkr.ecr.us-east-2.amazonaws.com, quay.io for vendored upstream, docker.io/bitnamilegacy/*); other registries rejected
- An unsigned image push to ECR + helmrelease attempt is rejected at admission
- A NetworkPolicy violation produces a clear admission error message

Design reference: Section 9 + Section 10 of the QA stand-up Confluence page.""",
    },
    {
        "summary": "QA App onboarding: generalize platform-app-expose chart for multi-env",
        "story_points": 5,
        "phase": "Phase 4 -- Application + governance",
        "description": """Refactor INFRA-1527's platform-app-expose chart to accept env as a parameter.

Acceptance criteria:
- Chart values accept env: dev|qa|prod
- Per-env Istio Gateway selection emitted
- Per-env ExternalSecret store ref emitted (op-usxpress-{env}/*)
- Per-env IRSA annotation pattern (op-usxpress-{env}-<workload>-<purpose>)
- Per-env ServiceMonitor label emitted matching env-specific Prometheus selector
- A single values file with env: qa onboards the workload to QA
- The same values file with env: dev still works against Dev (regression test)
- Documentation updated to reflect the multi-env pattern

Design reference: Section 12 of the QA stand-up Confluence page.""",
    },
    {
        "summary": "QA App onboarding: onboard first application to QA via generalised chart",
        "story_points": 3,
        "phase": "Phase 4 -- Application + governance",
        "description": """Onboard a representative application to QA (e.g. brands-api or geo-handler) using the multi-env platform-app-expose chart.

Acceptance criteria:
- One application onboarded to QA via the chart from the prior ticket
- ExternalSecret reads from op-usxpress-qa/*
- IRSA role bound and verified
- Istio VirtualService routes traffic on the op-qa subdomain
- Grafana dashboard for the workload picks up the ServiceMonitor automatically (sidecar discovery)
- A test request returns the expected response

Design reference: Section 12 of the QA stand-up Confluence page.""",
    },
    {
        "summary": "QA Governance: Path-to-Production gates (branch protection + Octopus approvals)",
        "story_points": 5,
        "phase": "Phase 4 -- Application + governance",
        "description": """Enforce the promotion gates from Section 13 of the design.

Acceptance criteria:
- iaac-talos-flux-platform op-qa branch: branch protection with required Cloud Platform reviewer
- iaac-talos-flux-platform op-prod branch: branch protection with two required reviewers (Cloud Platform + a designated second)
- iaac-talos feature/op-usxpress-qa: Octopus TfApply with Cloud Platform team review step
- iaac-talos feature/op-usxpress-prod (future): Octopus TfApply with two-person review step and change-window gate
- Documentation in the Confluence page section 13 reflects the actual GitHub branch protection rules

Design reference: Section 13 of the QA stand-up Confluence page.""",
    },
    {
        "summary": "QA DR: full cluster loss restore drill",
        "story_points": 8,
        "phase": "Phase 4 -- Application + governance",
        "description": """Hold the most important DR drill per Section 7.3 item 3.

Acceptance criteria:
- Schedule the drill within 30 days of QA stand-up
- Procedure: terraform-destroy the cluster, re-provision from iaac-talos, restore etcd from S3 snapshot, wait for Flux to bring the platform back, restore tenant PVCs from Velero
- Time-to-recovery measured against the RTO target in Section 7.1 (4 hours)
- Drill writeup documented as a memory file and shared with the team
- Any gaps identified during the drill become follow-up tickets

This drill is the gate for declaring QA production-ready and for Prod stand-up to proceed from this baseline.

Design reference: Section 7 of the QA stand-up Confluence page.""",
    },
]

print(f"\nFiling {len(tickets)} sub-tickets under {EPIC_KEY}...")
created_keys = []
for t in tickets:
    fields = {
        "project": {"key": "INFRA"},
        "summary": t["summary"],
        "issuetype": {"name": "Task"},
        "labels": ["onprem", "qa", "production-readiness", "op-usxpress-qa", t["phase"].replace(" ", "-").replace("--", "").lower()[:30]],
        "assignee": {"accountId": DOKE_ACCOUNT_ID},
        "description": adf(t["description"] + f"\n\nPhase: {t['phase']}"),
        "parent": {"key": EPIC_KEY},
        STORY_POINTS_FIELD: t["story_points"],
    }
    try:
        res = api(f"{JIRA_BASE}/rest/api/3/issue", "POST", {"fields": fields})
        created_keys.append((res["key"], t["story_points"], t["summary"]))
        print(f"  {res['key']:10s} {t['story_points']:>2}pt  {t['summary']}")
    except Exception as e:
        print(f"  FAILED: {t['summary']} -- {e}")

print(f"\n=== Summary ===")
print(f"Confluence page: {CONF_URL}/spaces/{SPACE}/pages/{PAGE_ID}")
print(f"Epic: {JIRA_BASE}/browse/{EPIC_KEY}")
print(f"Sub-tickets filed: {len(created_keys)}")
print(f"Total story points: {sum(t[1] for t in created_keys)}")
