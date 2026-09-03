#!/usr/bin/env python3
"""Record 2026-09-03 on the INFRA board: evidence comments, status moves, one sprint removal.

Every move below is backed by something checked against the live cluster today, and the
comment says what was checked. Nothing moves on "the PR merged" alone -- four layers between
a merge and a running process each reported Ready while the next was stale (see
wip/rw-etl-promotion/FLEET-2026-09-03.md).

INFRA-1674 deliberately gets a comment and NO transition: the stack is running, but Velero
has still never produced a backup, and whether that blocks "done" is Doke's call, not this
script's.

DRY-RUN BY DEFAULT. Pass --go to write.
Auth: export ATLASSIAN_TOKEN=...
"""
import base64
import json
import os
import sys
import urllib.error
import urllib.request

GO = "--go" in sys.argv
BASE = "https://usxpress.atlassian.net"
EMAIL = os.environ.get("JIRA_EMAIL", "doke@usxpress.com")
SPRINT = 1041          # UI Sprint 4

# ── comments + the status each ticket should end in (None = comment only) ─────
WORK = {
"INFRA-1689": ("Done", """2026-09-03 — DONE, verified at the process.

Two halves, both needed, and the second was only found while diagnosing the first.

1. infrastructure/grafana/virtualservice.yaml on op-prod claimed grafana.op-dev.usxpress.io
   and carried op-dev's seven ingress IPs. This was not a collision: external-dns keys
   ownership on --txt-owner-id, so prod SKIPPED a record dev owns and prod Grafana had no
   working hostname at all, silently, with every status field green.
   variant-inc/iaac-talos-flux-platform#148, targets derived from prod's own verified argocd
   route (ten platform nodes, not dev's seven -- the lists are not transferable).

2. helm-values-configmap.yaml still set Grafana's own server.domain and root_url to the dev
   hostname, so the corrected route would have sent users back to dev on login redirect,
   alert links and the OAuth callback. #149.

Verified: scripts/onprem-dns-claims.sh prod reports ZERO mismatches for the first time;
dig grafana.op-prod.usxpress.io returns prod's ten node IPs; the rendered grafana.ini holds
root_url = https://grafana.op-prod.usxpress.io/ and pod grafana-68c9dd895b-rt9c7 started
20:49:04Z, after that config changed.

Note for next time: the first PR searched for a VirtualService and found one of the two
places the hostname was written. grep -rn on the branch for the hostname finds both."""),

"INFRA-1687": ("Done", """2026-09-03 — DONE. Licence obtained and confirmed in use.

Compact JWT, issuer prod.risingwave.com, tier "all", EXPIRES 2026-10-15.

Confirmed present and valid by reading the VALUE back (not the ExternalSecret condition) in
all four RisingWave namespaces: op-dev/risingwave, op-dev/risingwave-2, op-qa/risingwave and
op-prod/risingwave, via scripts/rw-fleet-licence-status.sh.

⚠️ 41 days of validity remain. scripts/rw-prod-status.sh gate 5 and the fleet check both
start reporting NOT DONE on 2026-09-15, giving 30 days' notice. A renewal needs starting
well before then -- raise a follow-up rather than relying on the gate to remember."""),

"INFRA-1688": ("Done", """2026-09-03 — DONE. Console is running on a real licence.

risingwave-console on op-usxpress-prod is 2/2 Running and stable; it had 532 restarts while
the placeholder PLACEHOLDER_INJECT_REAL_LICENSE was in place. rw-bootstrap-service-accounts
was a terminal Failed Job holding Kustomization risingwave-onprem at Ready=False -- a Failed
Job never retries, so it was deleted and Flux recreated it. It now reports Complete 1/1 in 5s
and risingwave-onprem is Ready=True.

QA confirmed too: op-qa/risingwave holds the same valid JWT.

One belief this corrected: the console picked the new licence up WITHOUT the pod being
recreated, which contradicts the usual secretKeyRef-resolves-at-pod-creation rule. It most
likely mounts the secret as a volume. Recorded as unconfirmed -- worth reading the pod spec
before generalising, because the "recreate the pod" step is right for other workloads."""),

"INFRA-1650": ("Done", """2026-09-03 — DONE. Verified, and previously only recorded in the repo.

Argo CD on op-usxpress-prod can read variant-inc repositories: deploy key
argocd-op-usxpress-prod (id 162114773, read-only) on variant-inc/risingwave-pipeline, private
half in op-usxpress-prod/platform/argocd as repo.risingwave-pipeline.sshPrivateKey, delivered
by an ExternalSecret carrying the argocd.argoproj.io/secret-type: repository label in its
template (ESO does not copy labels from the ExternalSecret to the Secret it creates).

Verified after merge: op-prod moved 7f0d3b7 -> b0cd4c4 and the Secret's sshPrivateKey decodes
to a real OpenSSH private key."""),

"INFRA-1639": ("In Progress", """2026-09-03 — moving to In Progress; the build is done, the acceptance test is not.

Argo CD access is managed by group on all three clusters. Three tiers, one Entra group each:
usx-argocd-admin -> platform-admin, usx-argocd-operator -> app-operator, usx-argocd-viewer ->
app-viewer. Granting access is adding someone to a group. Landed by
iaac-talos-flux-platform#145, #146 and #147, verified live in argocd-rbac-cm on op-prod, and
tenant-wide admin consent was granted by direct Graph POST to /v1.0/oauth2PermissionGrants
(az ad app permission admin-consent exits 0 and does nothing here, because the registration
declares no requiredResourceAccess).

Remaining: role:app-operator has never been exercised by a real person. Pujit Koirala's first
sign-in is the acceptance test, and this closes on that."""),

# Comment only. The stack runs; the backup does not exist. That is Doke's call, not mine.
"INFRA-1674": (None, """2026-09-03 — RisingWave is fully deployed and running on op-usxpress-prod.

scripts/rw-prod-status.sh: 15 gates done, 1 not done, 1 unknown.

Done today: the console licence is real (see INFRA-1687/1688), rw-bootstrap-service-accounts
was a terminal Failed Job and now reports Complete 1/1, and Kustomization risingwave-onprem
is Ready=True. All 13 pods Running. ExternalSecrets synced AND holding real content. Routes,
Gateways and DNS verified for risingwave-dashboard and risingwave-overview.

NOT DONE, and the reason this is not being closed automatically:
- Velero Schedule risingwave-metastore exists but has produced NO completed backup in 45h.
  Prod RisingWave has no restore point. Whether that blocks "done" or belongs in its own
  ticket is a judgement call, so this script leaves the status alone.
- Gate 1 (AWS layer) reads UNKNOWN without an ops-controller session; re-run after
  aws sso login --profile ops-controller to turn it green or red."""),
}

# INFRA-345 is a Done RPA ticket of Charlie Lee's from 2024-04-09 sitting in Sprint 4.
BACKLOG = ["INFRA-345"]


def token():
    t = os.environ.get("ATLASSIAN_TOKEN") or os.environ.get("CONFLUENCE_TOKEN")
    if t:
        return t.strip()
    sys.exit("No token: export ATLASSIAN_TOKEN=...")


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


def preflight():
    """Jira answers an unauthorised read with 404 and an unauthorised create with 400 --
    both read as permissions problems, not auth ones. Enforced by
    scripts/lint-jira-preflight.sh after this cost two sessions."""
    s, r = api("GET", "/rest/api/3/myself")
    if s != 200:
        print(f"!! cannot authenticate to {BASE} as {EMAIL} (HTTP {s})")
        print("   read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo")
        sys.exit(1)
    print(f"authenticated as {r.get('displayName')} <{r.get('emailAddress', EMAIL)}>\n")


def adf(text):
    return {"type": "doc", "version": 1, "content":
            [{"type": "paragraph", "content": [{"type": "text", "text": p}]}
             for p in text.split("\n\n") if p.strip()]}


preflight()
print(f"{'EXECUTING' if GO else 'DRY RUN'} — {EMAIL} @ {BASE}\n")

for key, (want, body) in WORK.items():
    s, cur = api("GET", f"/rest/api/3/issue/{key}?fields=summary,status")
    if s != 200:
        print(f"  {key}: cannot read ({s}) — skipped")
        continue
    now = cur["fields"]["status"]["name"]
    print(f"  {key}  [{now}]  {cur['fields']['summary'][:52]}")

    if not GO:
        print(f"     [plan] comment ({len(body)} chars)"
              + (f", transition {now} -> {want}" if want and want != now else ""))
        continue

    s, r = api("POST", f"/rest/api/3/issue/{key}/comment", {"body": adf(body)})
    print(f"     comment: {'OK' if s in (200, 201) else f'FAIL {s} {r}'}")

    if not want or want == now:
        continue
    # Resolve the transition BY NAME. Ids differ per workflow and hardcoding one is how a
    # script silently moves a ticket to the wrong column.
    s, tr = api("GET", f"/rest/api/3/issue/{key}/transitions")
    match = [t for t in tr.get("transitions", []) if t["to"]["name"].lower() == want.lower()]
    if not match:
        avail = ", ".join(t["to"]["name"] for t in tr.get("transitions", []))
        print(f"     transition to '{want}' NOT AVAILABLE. Reachable: {avail}")
        continue
    s, r = api("POST", f"/rest/api/3/issue/{key}/transitions", {"transition": {"id": match[0]["id"]}})
    print(f"     {now} -> {want}: {'OK' if s in (200, 204) else f'FAIL {s} {r}'}")

print("\n== remove from sprint (to backlog)")
for key in BACKLOG:
    if not GO:
        print(f"  [plan] {key} -> backlog (off sprint {SPRINT})")
        continue
    s, r = api("POST", "/rest/agile/1.0/backlog/issue", {"issues": [key]})
    print(f"  {key} -> backlog: {'OK' if s in (200, 204) else f'FAIL {s} {r}'}")

print("""
Left for you, deliberately:
  INFRA-1674  running, but Velero has produced no backup. Close it, or split the backup out.
  INFRA-1637  Idris — was the Confluent key REVOKED, or only replaced? Most urgent open item.
  Sprint 4    still state=future. Start it.
  New ticket  op-dev risingwave-2 Prometheus filled its PVC (fixed today) — file if you want
              the work traceable on the board; it is written up in the repo either way.""")
