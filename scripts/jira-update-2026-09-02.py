#!/usr/bin/env python3
"""Record 2026-09-02's work on the INFRA board.

Comments only, plus one new ticket. It does NOT transition anything: whether INFRA-1639
and INFRA-1650 are Done depends on Pujit's first sign-in and on your view of scope, and
guessing that from a script is how a board stops being trusted.

DRY-RUN BY DEFAULT. Pass --go to write.
Auth (WSL): export ATLASSIAN_TOKEN=...
"""
import base64, json, os, sys, urllib.error, urllib.request

GO = "--go" in sys.argv
BASE = "https://usxpress.atlassian.net"
EMAIL = os.environ.get("JIRA_EMAIL", "doke@usxpress.com")
PROJECT = "INFRA"

COMMENTS = {
"INFRA-1674": """2026-09-02 — RisingWave is deployed and RUNNING on op-usxpress-prod.

Terraform: Octopus release 0.5.6 to production, TfApply armed for one run then disarmed.
Apply complete, 20 added, 0 changed, 0 destroyed; terraform_outputs.yml captured. Created
in 937464026810/us-east-2: IRSA role op-usxpress-prod-risingwave with inline policy
risingwave-s3-access, s3://risingwave-state-op-usxpress-prod with versioning, SSE and
public-access-block, and five Secrets Manager entries under op-usxpress-prod/risingwave/.

Flux: variant-inc/iaac-talos-flux-cluster#38 merged. risingwave-operator and
risingwave-routes Ready; the RisingWave CR reports RUNNING=True on v2.8.2 with the
PostgreSQL metastore and S3 state store bound. meta, compute, frontend, compactor, both
ghostunnels and pg-postgresql all 1/1. The ServiceAccount carries the prod IRSA role.
VirtualServices for risingwave-dashboard and risingwave-overview are live and DNS resolves
for both. Prod's Dex callback was added to Entra registration e112d6ce-cc60-4884-9898-8fcc5b78b0b1.

Not done, which is why this stays In Progress: risingwave-console is in CrashLoopBackOff.
console_license_key holds the Terraform placeholder PLACEHOLDER_INJECT_REAL_LICENSE and the
console rejects it with "license verification failed: license must be a compact JWT". QA
holds the identical placeholder, so there is nothing to copy between environments. That one
value also crashloops rw-bootstrap-service-accounts, which completes every group, user and
grant and then fails on the console's own anclax schema. Velero Schedule
risingwave-metastore exists; no completed backup yet.

Two failed prod deploys preceded the successful one, both 403 on the Terraform state
backend: S3_BUCKET in production scope held QA's bucket, and after correcting it the
release still deployed its frozen variable snapshot.""",

"INFRA-1650": """2026-09-02 — DONE. Argo CD on op-usxpress-prod can read variant-inc repositories.

variant-inc/iaac-talos-flux-platform#144 merged: an ExternalSecret in
infrastructure/argocd-config/ delivering a per-repository deploy key, carrying the
argocd.argoproj.io/secret-type: repository label in the template (ESO does not copy labels
from the ExternalSecret to the Secret it creates).

Deploy key argocd-op-usxpress-prod (id 162114773, read-only) added to
variant-inc/risingwave-pipeline, beside the QA key from 2026-08-20. Private half written to
op-usxpress-prod/platform/argocd as repo.risingwave-pipeline.sshPrivateKey.

Caught before it shipped: that property did not exist when the PR was written, so it would
have merged, synced green, and left Argo CD holding a credential with no key in it. The
record also holds admin.password and put-secret-value replaces the whole JSON document, so
the write was done by merge with a read-back check that every prior property survived.

Verified after merge: op-prod moved 7f0d3b7 to b0cd4c4, and the Secret's sshPrivateKey
decodes to a real -----BEGIN OPENSSH PRIVATE KEY-----.""",

"INFRA-1639": """2026-09-02 — Argo CD access is now managed by group, on all three clusters.

Three tiers, one Entra group each. Granting access is adding someone to a group; nobody
edits Entra, raises a PR or touches a cluster.

  usx-argocd-admin     6c23655c-8080-4991-a67f-293cfb0a597b  -> platform-admin  (Idris Fagbemi)
  usx-argocd-operator  984faf3e-e280-490e-8ff4-a71101a73a95  -> app-operator    (Timothy Preble, Pujit Koirala)
  usx-argocd-viewer    6bd52028-9105-4bdf-a39a-0d31a57ae53b  -> app-viewer      (Jenni Ray)

New app role app-operator: read, logs, sync, action/* (the Restart button) and
resource-level delete, scoped to the apps AppProject, on dev, QA AND prod. app-viewer stays
read-only with sync on dev/QA. Landed by
variant-inc/iaac-talos-flux-platform#145, #146 and #147; verified live in argocd-rbac-cm on
op-prod.

Tenant-wide admin consent granted, consentType AllPrincipals, scope openid profile email.
Before this, the first sign-in by anyone who had not personally consented was routed to an
admin approval screen — which is what stopped Pujit Koirala. Note for the runbook:
`az ad app permission admin-consent` does NOT do this and exits 0 regardless, because it
grants only what the registration declares in requiredResourceAccess and this app declares
none. It took a direct Graph POST to /v1.0/oauth2PermissionGrants.

usx-cloud-admin has no owners, so its membership cannot be managed by anyone — hence the new
usx-argocd-admin group. Worth resolving separately.

Documented at docs/argocd-access/README.md.

Remaining before this can close: role:app-operator has never been exercised by a real
person. Pujit Koirala's first sign-in is the acceptance test.""",
}

NEW = [{
 "summary": "Remove the abandoned dpl and jbtest Talos clusters from Nutanix",
 "body": """Eleven VMs on usxd1vmvcntrapp belong to two abandoned Talos clusters and are all
powered on:

  talos-cp-dpl-1/2/3, talos-wk-dpl-1/2          5 VMs, 14 vCPU, 20 GB, 100 GB
  talos-cp-jbtest-1/2/3, talos-wk-jbtest-1/2/3  6 VMs, 18 vCPU, 24 GB,  90 GB

Neither appears in any Talos Terraform state. dpl is the original development cluster that
op-usxpress-dev replaced; jbtest is a test build that was never torn down.

They are exactly the gap in Jon Griffin's 8/27 figures: he counts 47 Talos VMs, 314 vCPU and
704 GB; Terraform state accounts for 36 VMs, 282 vCPU and 660 GB across dev, QA and prod.
32 vCPU and 44 GB, to the vCPU and to the gigabyte.

Acceptance criteria:
- Confirm nothing depends on jbtest before it is destroyed; the name suggests an individual
  owner rather than the platform
- Both clusters removed from vSphere
- scripts/talos-vm-reconcile.py --diff <inventory.csv> shows no unaccounted Talos VMs
- Jon Griffin's inventory reconciles against Terraform state with nothing left over

Context and the wider estate picture, including 26.2 TB held by powered-off VMs that are not
ours, is in wip/nutanix-capacity/talos-footprint-briefing.html.""",
}]


def token():
    t = os.environ.get("ATLASSIAN_TOKEN") or os.environ.get("CONFLUENCE_TOKEN")
    if t:
        return t.strip()
    sys.exit("No token: export ATLASSIAN_TOKEN=...   (run this on WSL)")


AUTH = "Basic " + base64.b64encode(f"{EMAIL}:{token()}".encode()).decode()


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method, headers={
        "Authorization": AUTH, "Accept": "application/json", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw[:400]}


def adf(text):
    return {"type": "doc", "version": 1, "content":
            [{"type": "paragraph", "content": [{"type": "text", "text": p}]}
             for p in text.split("\n\n") if p.strip()]}


print(f"{'EXECUTING' if GO else 'DRY RUN'} — {EMAIL} @ {BASE}\n")

print("== comments")
for key, body in COMMENTS.items():
    s, cur = api("GET", f"/rest/api/3/issue/{key}?fields=summary,status")
    if s != 200:
        print(f"  {key}: cannot read ({s}) — skipped"); continue
    print(f"  {key}  [{cur['fields']['status']['name']}]  {cur['fields']['summary'][:56]}")
    if not GO:
        print(f"     [plan] add comment, {len(body)} chars"); continue
    s, r = api("POST", f"/rest/api/3/issue/{key}/comment", {"body": adf(body)})
    print(f"     {'OK' if s in (200, 201) else f'FAIL {s} {r}'}")

print("\n== new tickets")
for spec in NEW:
    if not GO:
        print(f"  [plan] create: {spec['summary']}"); continue
    s, r = api("POST", "/rest/api/3/issue", {"fields": {
        "project": {"key": PROJECT}, "summary": spec["summary"],
        "description": adf(spec["body"]), "issuetype": {"name": "Task"}}})
    if s in (200, 201):
        print(f"  created {r['key']}: {spec['summary']}")
    else:
        print(f"  FAIL {s} {r}")

print("""
No status transitions were made. Decide these yourself:
  INFRA-1650  ready to close — the credential is live and verified
  INFRA-1639  hold until Pujit Koirala has signed in; that is its acceptance test
  INFRA-1674  hold until the RisingWave console licence lands""")
