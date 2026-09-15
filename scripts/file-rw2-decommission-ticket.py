#!/usr/bin/env python3
"""File the risingwave-2 decommission ticket to INFRA, and print the key.

Decision 2026-09-15 (Doke): one RisingWave per environment, always named `risingwave`.
`risingwave-2` on op-usxpress-dev is retired.

The ticket exists rather than a checklist because the namespace is not only RisingWave --
it hosts the Prometheus stack for the whole dev cluster, including a node-exporter
DaemonSet on all ten nodes -- and because several AWS objects are NAMED for risingwave-2
while SERVING `risingwave` on QA and prod. A sweep by name destroys live data.

    python3 scripts/file-rw2-decommission-ticket.py --dry-run
    python3 scripts/file-rw2-decommission-ticket.py
"""
import base64
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
EMAIL = "doke@usxpress.com"
PROJECT = "INFRA"
SITE = "https://usxpress.atlassian.net"

# scripts/push-to-confluence.sh is GITIGNORED -- it carries the Atlassian token and exists
# only where someone put it. Read the env var first and name both sources when neither is
# present, so a fresh clone fails with an instruction rather than a FileNotFoundError.
TOKEN = os.environ.get("JIRA_API_TOKEN", "")
src = "JIRA_API_TOKEN"
tokfile = REPO_ROOT / "scripts/push-to-confluence.sh"
if not TOKEN and tokfile.exists():
    for ln in tokfile.read_text().splitlines():
        if ln.startswith("CONFLUENCE_TOKEN="):
            TOKEN = ln.split("=", 1)[1].strip().strip('"').strip("'")
            src = str(tokfile)
            break
if not TOKEN:
    sys.exit("ERROR: no Atlassian token. Set JIRA_API_TOKEN, or create "
             "scripts/push-to-confluence.sh with a CONFLUENCE_TOKEN= line "
             "(gitignored, so it is absent in a fresh clone).")
print(f"token from {src}")
AUTH = "Basic " + base64.b64encode(f"{EMAIL}:{TOKEN}".encode()).decode()

SUMMARY = "Retire the risingwave-2 namespace and its AWS resources on op-usxpress-dev"

INTRO = [
    "Decision 2026-09-15: one RisingWave per environment, always named `risingwave`. "
    "op-usxpress-dev currently runs two. `risingwave-2` was stood up 2026-05-27 as the platform "
    "team's own space so our CI/CD work could not disturb Tim's; the application's pipeline has "
    "since been pointed back at `risingwave` (risingwave-pipeline PR #35), so nothing should "
    "target it any more.",

    "Verified on the cluster 2026-09-15, read-only:",
]
STATE = [
    "`risingwave-2` runs a complete RisingWave: operator, meta, compute, compactor, frontend, "
    "all 111 days old, plus a postgres StatefulSet holding its meta store (database "
    "`risingwave_meta`).",
    "It holds ZERO application objects. `rw_catalog` reports no sources, no materialized views "
    "and no sinks. Every Brand object on dev -- brand_source_kafka, brand_mv_raw, brand_mv_state, "
    "brand_mv_flat -- is in `risingwave`.",
    "It ALSO hosts the dev cluster's Prometheus stack: prometheus-server, kube-state-metrics, "
    "pushgateway, and a prometheus-node-exporter DaemonSet running on all 10 nodes. This is the "
    "blocker, not the RisingWave instance.",
    "It also hosts `ghostunnel-rw2-sql` (2/2), so an ingress route and a DNS record point at it.",
]
HAZARD_INTRO = [
    "DO NOT SWEEP BY NAME. Some AWS objects carry risingwave-2 naming but serve `risingwave` on "
    "QA and prod, because the Terraform module was written during the RW-2 work. Deleting these "
    "destroys the live object store for a running environment:",
]
HAZARD = [
    "KEEP: `risingwave-data-op-usxpress-qa` and `risingwave-data-op-usxpress-prod` are the "
    "Hummock object stores for `risingwave` on QA and prod. Rename at most, and a rename is a "
    "Terraform state migration, not a delete.",
    "KEEP: `risingwave_2_data` is a Terraform module/variable identifier used in all three "
    "environments. Renaming it touches QA and prod state.",
    "DELETE: `op-usxpress-dev/risingwave-2/*` in Secrets Manager (postgres, root, "
    "console_license_key, secret_store_private_key).",
    "DELETE: the dev bucket `op-usxpress-dev-risingwave-2`.",
    "DELETE LAST: `gha-op-usxpress-dev-risingwave-pipeline-secrets` and "
    "`gha-op-usxpress-qa-risingwave-pipeline-secrets`. These grant `.../risingwave-2/*` only and "
    "are dead once PR #35 is merged everywhere -- but confirm no workflow assumes them first.",
]
NOTE_TWO_PROJECTS = [
    "Note that `iaac-talos` and `iaac-risingwave-onprem` both declare RisingWave's bucket and "
    "IRSA role. A destroy run in the wrong project takes the object store with it. Read the plan "
    "before every apply; a count that collapses to zero is a destroy switch, not a no-op.",

    "Do these in order. Removing the namespace before the configuration that creates it just "
    "means Flux puts it back:",
]
STEPS = [
    "Finish the pipeline move. Merge risingwave-pipeline PR #35 to master, copy the workflow to "
    "the `qa` and `dev` branches (a workflow file only runs from the branch receiving the push), "
    "and change the GitHub `dev` environment to "
    "RISINGWAVE_HOST=risingwave-frontend.risingwave.svc.cluster.local and "
    "POSTGRES_HOST=postgres-postgresql.risingwave.svc.cluster.local. Ports are unchanged.",
    "Prove it: one merge to `dev` runs green against `risingwave`. Until this passes, do not "
    "start deleting -- a broken pipeline and a deleted namespace are hard to tell apart.",
    "DECIDE the Prometheus question. Is the stack in `risingwave-2` the dev cluster's only "
    "metrics source, or is there a platform stack elsewhere? If it is the only one, relocate it "
    "to a platform namespace BEFORE the namespace is deleted; if it is redundant, confirm that by "
    "pointing at the stack that replaces it. Its prometheus-server has been in CrashLoopBackOff "
    "past 1566 restarts, so it may be a retire rather than a move -- but that is a decision, not "
    "an assumption.",
    "Remove the ingress route, VirtualService and DNS record for `ghostunnel-rw2-sql`, and "
    "confirm the hostname stops resolving.",
    "Remove risingwave-2 from the sources that create it, repo by repo, and let each reconcile: "
    "iaac-risingwave-2, iaac-risingwave-onprem, iaac-talos-flux-platform, iaac-talos-flux-cluster, "
    "iaac-talos, iaac-risingwave-cicd. Config first, cluster second.",
    "Delete the namespace, and check nothing recreates it after a full reconcile interval.",
    "Delete the AWS objects on the DELETE list above, in that order. Re-read the Terraform plan "
    "each time and confirm 0 unexpected destroys before applying.",
    "Update the docs that describe the two-namespace model: wip/rw2-sql-cicd/, the "
    "iaac-risingwave-cicd README, and the RisingWave architecture docs.",
]
CLOSE = [
    "Risk and rollback: the RisingWave instance in `risingwave-2` holds no application objects, "
    "so losing it costs nothing. The two things that would hurt are deleting a QA or prod object "
    "store by name, and blinding dev's monitoring -- steps 3 and the KEEP list address both. "
    "Nothing in this ticket touches QA or prod workloads.",

    "Definition of done: `kubectl get ns risingwave-2` returns NotFound on op-usxpress-dev and "
    "stays that way through a reconcile; no repo references risingwave-2 except as history; the "
    "dev pipeline runs green against `risingwave`; QA and prod object stores are untouched and "
    "still serving.",
]


def _list(items):
    return {"type": "bulletList", "content": [
        {"type": "listItem", "content": [
            {"type": "paragraph", "content": [{"type": "text", "text": i}]}]}
        for i in items]}


def adf():
    c = []
    for p in INTRO:
        c.append({"type": "paragraph", "content": [{"type": "text", "text": p}]})
    c.append(_list(STATE))
    for p in HAZARD_INTRO:
        c.append({"type": "paragraph", "content": [{"type": "text", "text": p}]})
    c.append(_list(HAZARD))
    for p in NOTE_TWO_PROJECTS:
        c.append({"type": "paragraph", "content": [{"type": "text", "text": p}]})
    c.append(_list(STEPS))
    for p in CLOSE:
        c.append({"type": "paragraph", "content": [{"type": "text", "text": p}]})
    return {"type": "doc", "version": 1, "content": c}


def api(method, path, body=None):
    req = urllib.request.Request(
        SITE + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": AUTH, "Accept": "application/json",
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        sys.exit(f"ERROR {e.code} on {method} {path}\n{e.read()[:600].decode(errors='replace')}")


# Jira reports an unauthorised read as 404 and an unauthorised create as 400 "the target
# project doesn't exist" -- neither says "bad token". Prove the token first.
me = api("GET", "/rest/api/3/myself")
print(f"authenticated as {me.get('emailAddress') or me.get('displayName')}")
proj = api("GET", f"/rest/api/3/project/{PROJECT}")
print(f"project {proj['key']} ({proj['id']}) {proj['name']}")

payload = {"fields": {"project": {"key": PROJECT}, "summary": SUMMARY,
                      "issuetype": {"name": "Task"}, "description": adf()}}

if "--dry-run" in sys.argv:
    print("\n--- DRY RUN, nothing filed ---")
    print(SUMMARY)
    for b in STEPS:
        print("  step:", b[:110])
    sys.exit(0)

ans = input(f"\nfile '{SUMMARY}' to {PROJECT}? type yes: ")
if ans != "yes":
    sys.exit("aborted, nothing filed.")

issue = api("POST", "/rest/api/3/issue", payload)
print(f"\nfiled {issue['key']}  {SITE}/browse/{issue['key']}")
print("API-created tickets land in the BACKLOG, not the active sprint -- move it if it is for now.")
