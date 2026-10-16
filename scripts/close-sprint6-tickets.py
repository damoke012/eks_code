#!/usr/bin/env python3
"""Close the UI Sprint 6 tickets that are genuinely finished. DRY RUN until --go.

Four qualify. The other four do NOT, and each is excluded for a stated reason rather
than left out silently:

  1708 - the pin is on a BRANCH. actions-collection#99 is green but unmerged (CODEOWNERS
         review from lazy-devs). master still reads trivy-action@master, so closing it
         would claim a fix that is not live.
  1705 - its DONE WHEN needs a named owner's decision on Brand/300-transform.sql, the
         loser deleted, and QA confirmed on the agreed set. None of the three has happened;
         risingwave-pipeline#126 is the GUARD that makes the deletion safe, not the deletion.
  1709 - "the Job actually applying SQL" on QA is unmeasured. SHOW SOURCES/SINKS decides it.
  1706 - not started.

Each close carries a comment. A ticket closed without a record of why is how Sprint 5
ended with "3 committed, 0 completed" and a rollover nobody could reconstruct.

    read -rsp 'Atlassian API token: ' T; export ATLASSIAN_TOKEN="$T"; echo
    python3 scripts/close-sprint6-tickets.py          # shows what it would do
    python3 scripts/close-sprint6-tickets.py --go     # comments and closes
"""
import importlib.util, os, sys

spec = importlib.util.spec_from_file_location(
    "closer", os.path.join(os.path.dirname(os.path.abspath(__file__)), "close-sprint3-tickets.py"))
m = importlib.util.module_from_spec(spec)
_argv = sys.argv[:]; sys.argv = ["x"]
spec.loader.exec_module(m)
sys.argv = _argv

GO = "--go" in sys.argv
m.GO = GO          # do_comment / do_close read the module-level GO

CLOSE = [
    ("INFRA-1707",
     "Both DONE WHEN conditions met.\n\n"
     "Alerts: 0 open Dependabot alerts on the default branch. Measured with stderr "
     "visible (exit 0, 40682 bytes of response) because a 403 from a missing scope "
     "returns the same empty list as a clean repo.\n\n"
     "Renovate branch: renovate/major-github-actions-dependencies rebased onto main, "
     "now ahead 1 / behind 0 where it was ahead 1 / behind 4 / diverged. "
     ".github/workflows/publish-applier.yml is present after the rebase - that file "
     "builds the sql-applier image every on-prem app build depends on, so its survival "
     "was the gate on this, not the diff being small."),

    ("INFRA-1703",
     "Split at the close of UI Sprint 6. Remainder is INFRA-1716.\n\n"
     "Done here: the three artefacts are inventoried (operator chart v0.1.36, engine "
     "v2.8.2, console); v2.8 left support 2026-10-11 so staying put is now a decision "
     "rather than a default; the target is v3.1.x and not v3.0; dev's console version "
     "was corrected by iaac-risingwave-onprem#52.\n\n"
     "Carried to INFRA-1716: the restore drill (the meta store is a separate Bitnami "
     "PostgreSQL chart outside the RisingWave CR, so a restore is two systems and the "
     "pair has never been proven to come back together), QA and prod consoles still "
     "reporting v2.8.2, the console DNS fix, and whether the operator supports engine 3.x "
     "- that last one decides whether the upgrade is one step or two."),

    ("INFRA-1704",
     "Split at the close of UI Sprint 6. Remainder is INFRA-1717.\n\n"
     "Done here: all six expired certificates on op-dev were replaced on 2026-10-06, and "
     "the root cause is established - pod-identity-webhook is failurePolicy Ignore and was "
     "unavailable when the cert-manager pod was created, so it ran 109 days with no AWS "
     "credentials and the Route53 DNS-01 solver could never run.\n\n"
     "Carried to INFRA-1717, which is the prevention half: no ServiceMonitor exists for "
     "cert-manager on any cluster though its metrics Service always has; the expiry rule "
     "must read .status.notAfter because Ready:True was served throughout the 41-day "
     "outage; and prod has no Alertmanager, so delivery there is a prerequisite and not "
     "a follow-up."),

    ("INFRA-1696",
     "Split at the close of UI Sprint 6. Remainder is INFRA-1718.\n\n"
     "Done here: build book sections 01-05 and 07 exist, and the QA2 rehearsal of "
     "2026-09-17/18 produced five concrete IaC corrections which are recorded.\n\n"
     "Carried to INFRA-1718: sections 06 and 08-12, QA2-STANDUP.md, and applying the five "
     "corrections to the IaC rather than only documenting them.\n\n"
     "This item carried from Sprint 5 and then Sprint 6. INFRA-1718 should be split per "
     "document if it does not finish next sprint - re-estimating it as one item is what "
     "has failed twice."),

    ("INFRA-1709",
     "Closing. Measured on op-usxpress-qa 2026-10-16 with scripts/rw-sql.sh:\n\n"
     "SOURCES (2): public.brand_source_kafka, public.activeresource_source_kafka\n"
     "MATERIALIZED VIEWS (4): public.brand_mv_raw, public.brand_mv_state, "
     "public.brand_mv_flat, public.canary_promotion_mv\n"
     "SINKS (1): public.activeresource_sink\n\n"
     "So the objects exist at the destination - the Job is applying SQL, not merely "
     "reporting Succeeded. No Employee objects, which is correct: Employee is excluded "
     "on QA by EXCLUDE_RE. The canary MV is there too, so the promotion path has run "
     "end to end.\n\n"
     "Scope items 1-3 are done: the chart is in a repo Argo CD reads "
     "(risingwave-pipeline deploy/chart), values-qa.yaml pins the image by DIGEST, and "
     "the Application on op-usxpress-qa is Synced/Succeeded over real objects.\n\n"
     "ONE CRITERION DELIBERATELY NOT MET. This ticket asks for QA to pick up a new "
     "digest 'without a human touching anything but the merge button'. PR #122 made QA "
     "and prod promotion DISPATCH-ONLY on purpose: a scheduled run has no inputs, so "
     "only dev can pass the gate. Before that, one 10-minute tick could carry an image "
     "ECR -> dev -> QA -> prod-PR with zero soak. The criterion is out of date, not the "
     "system. Automatic QA promotion is a separate decision if it is still wanted.\n\n"
     "Scope item 5 - retiring the duplicated pipelines/ in risingwave-pipeline - is "
     "INFRA-1705 and stays there."),
]

SKIP = [
    ("INFRA-1708", "pin is on an unmerged branch; master still reads trivy-action@master"),
    ("INFRA-1705", "needs Tim on Brand/300-transform.sql, then the deletion"),
    ("INFRA-1706", "not started"),
]


def main():
    print("== close-sprint6-tickets  " +
          ("EXECUTING" if GO else "DRY RUN (pass --go to execute)") + "\n")
    m.preflight()

    for key, body in CLOSE:
        s, iss = m.api("GET", f"/rest/api/3/issue/{key}?fields=status,summary")
        if s != 200:
            print(f"!! {key} unreadable ({s}) - skipped, nothing changed")
            continue
        st = ((iss.get("fields") or {}).get("status") or {}).get("name", "?")
        print(f"-- {key}  [{st}]  {(iss.get('fields') or {}).get('summary','')[:58]}")
        if st.lower() in ("done", "closed", "resolved"):
            print("   already closed, nothing to do")
            continue
        m.do_comment(key, body)
        m.do_close(key)

    print("\nNOT closed, by design:")
    for key, why in SKIP:
        print(f"  {key}: {why}")


if __name__ == "__main__":
    main()
