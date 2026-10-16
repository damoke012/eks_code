#!/usr/bin/env python3
"""File successor tickets for the UI Sprint 6 items that cannot finish in the sprint.

DRY RUN by default. Creates nothing until --go.

Why successors rather than a carry-over: UI Sprint 5 closed "3 committed, 0 completed"
and all three moved to Sprint 6 with a comment as the only record. A ticket that carries
twice stops describing work and starts describing a backlog. Splitting states what the
sprint actually achieved and what is genuinely left, so the next sprint commits to the
remainder and not to the original wish.

Each successor copies its predecessor's issuetype (so the type is always valid for the
project) and is linked "Relates" to it.

    read -rsp 'Atlassian API token: ' T; export ATLASSIAN_TOKEN="$T"; echo
    python3 scripts/file-sprint6-successors.py          # shows what it would create
    python3 scripts/file-sprint6-successors.py --go     # creates them
"""
import importlib.util, os, sys

spec = importlib.util.spec_from_file_location(
    "closer", os.path.join(os.path.dirname(os.path.abspath(__file__)), "close-sprint3-tickets.py"))
m = importlib.util.module_from_spec(spec)
_argv = sys.argv[:]; sys.argv = ["x"]
spec.loader.exec_module(m)
sys.argv = _argv

GO = "--go" in sys.argv

SUCCESSORS = [
    {
        "parent": "INFRA-1703",
        "summary": "RisingWave upgrade: restore drill, and the stale console version on QA and prod",
        "labels": ["risingwave", "onprem", "upgrade"],
        "done": [
            "Three artefacts inventoried: operator chart v0.1.36, engine v2.8.2, console.",
            "v2.8 left support 2026-10-11, so staying put is now a decision, not a default.",
            "Target identified as v3.1.x, not v3.0; the operator's 3.x support is the gate.",
            "Dev's console version corrected by iaac-risingwave-onprem#52.",
        ],
        "left": [
            "The RisingWave console records the cluster version in its OWN database and only"
            " when absent, so QA and prod UIs still report v2.8.2 after the upgrade. Same fix"
            " as dev, applied to both.",
            "No restore path has been drilled. The meta store is a SEPARATE Bitnami PostgreSQL"
            " chart outside the RisingWave CR, so a restore is two systems, not one, and"
            " nothing proves the pair can come back together.",
            "Console DNS still unfixed.",
            "Whether the operator supports engine 3.x is still unmeasured, and it decides"
            " whether the upgrade is one step or two.",
        ],
    },
    {
        "parent": "INFRA-1704",
        "summary": "Cert expiry alerting: the ServiceMonitor, the rules, and prod's missing Alertmanager",
        "labels": ["onprem", "monitoring", "certificates"],
        "done": [
            "All six expired certificates on op-dev were replaced the same day (2026-10-06).",
            "Root cause established: pod-identity-webhook is failurePolicy Ignore and was"
            " unavailable when the cert-manager pod was created, so it ran 109 days with no"
            " AWS credentials and the Route53 DNS-01 solver could never run.",
        ],
        "left": [
            "Nothing scrapes cert-manager on any cluster. Its metrics Service has existed all"
            " along (cert-manager/cert-manager, port 9402) with NO ServiceMonitor.",
            "No expiry rule exists. It must read .status.notAfter: Ready:True was served"
            " throughout the 41-day outage, so Ready is not the signal.",
            "PROD HAS NO ALERTMANAGER. A rule that fires there reaches nobody, so prod"
            " delivery is a prerequisite, not a follow-up.",
            "The IRSA rules that cannot fire are still unfixed, which is the half of this"
            " ticket that prevents recurrence rather than detecting it.",
        ],
    },
    {
        "parent": "INFRA-1696",
        "summary": "Build book: the seven missing documents and the IaC rewiring QA2 exposed",
        "labels": ["documentation", "iac", "onprem"],
        "done": [
            "Build book sections 01-05 and 07 exist.",
            "The QA2 rehearsal (2026-09-17/18) produced five concrete IaC corrections,"
            " which are recorded.",
        ],
        "left": [
            "Sections 06 and 08-12 do not exist, and QA2-STANDUP.md is unfinished.",
            "The five corrections are documented but NOT applied to the IaC: the state bucket"
            " being per-account, the console-only lifecycle phase, the absent"
            " <cluster>/octopus-worker secret, and the rest.",
            "Carried from Sprint 5 and then Sprint 6. If it carries a third time it needs"
            " splitting per document, not re-estimating as one item.",
        ],
    },
]


def adf_block(d):
    parts = ["Successor to " + d["parent"] + ", filed at the close of UI Sprint 6.", "",
             "ALREADY DONE on " + d["parent"] + ":"]
    parts += ["- " + x for x in d["done"]]
    parts += ["", "STILL OPEN, which is this ticket:"]
    parts += ["- " + x for x in d["left"]]
    return "\n\n".join(parts)


def main():
    print("== file-sprint6-successors  " +
          ("EXECUTING" if GO else "DRY RUN (pass --go to execute)") + "\n")
    m.preflight()

    for d in SUCCESSORS:
        s, par = m.api("GET", f"/rest/api/3/issue/{d['parent']}?fields=issuetype,summary")
        if s != 200:
            print(f"!! {d['parent']} unreadable ({s}) - skipping, nothing created")
            continue
        itype = (par.get("fields") or {}).get("issuetype", {}).get("id")
        itname = (par.get("fields") or {}).get("issuetype", {}).get("name")
        print(f"-- {d['parent']} [{itname}] -> {d['summary']}")
        body = adf_block(d)
        if not GO:
            print("   [plan] would create, " + str(len(body)) + " chars of description")
            print("   " + body[:160].replace("\n", " ") + " ...")
            continue
        payload = {"fields": {
            "project": {"key": "INFRA"},
            "summary": d["summary"],
            "description": m.adf(body),
            "issuetype": {"id": itype},
            "labels": d["labels"],
        }}
        cs, resp = m.api("POST", "/rest/api/3/issue", payload)
        if cs not in (200, 201):
            print(f"   !! create failed {cs}: {str(resp)[:200]}")
            continue
        key = resp.get("key")
        print(f"   created {key}")
        link = {"type": {"name": "Relates"},
                "inwardIssue": {"key": key},
                "outwardIssue": {"key": d["parent"]}}
        ls, lr = m.api("POST", "/rest/api/3/issueLink", link)
        print(f"   link to {d['parent']}: {ls}" + ("" if ls in (200, 201) else f" {str(lr)[:120]}"))

    print("\nAPI-created tickets land in the BACKLOG, not the next sprint - move them"
          " deliberately on the board.")


if __name__ == "__main__":
    main()
