#!/usr/bin/env python3
"""Four decisions from reading the descriptions of six Sprint 3 tickets.

Not one of the three suspected duplicate pairs was a duplicate in the way the
titles suggested. Reading them produced better answers than closing them would
have:

  1636/1650 -- a real dependency pair, mislabelled. 1650 says "Depends on
               INFRA-1636" in its own description while its TITLE claims the
               ApplicationSet that 1636 owns. Re-scope the title; close neither.
  1625/1649 -- the same fix written twice. Close 1649 into 1625, carrying its
               extra incident dates. Both blocked on Azure access.
  1627/1659 -- NOT duplicates, and that is worse: two different delivery
               architectures for one cluster. Needs a decision, not a close.

DRY-RUN BY DEFAULT. Pass --go.
Auth:  read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo
"""
import importlib.util, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("closer", os.path.join(HERE, "close-sprint3-tickets.py"))
m = importlib.util.module_from_spec(spec)
_argv = sys.argv[:]; sys.argv = ["x"]
spec.loader.exec_module(m)
sys.argv = _argv
GO = "--go" in sys.argv

RETITLE = {
    "INFRA-1650": "Argo CD Git credential on op-usxpress-prod (ApplicationSet is INFRA-1636)",
}

COMMENTS = {
 "INFRA-1650": (
    "DECISION 2026-08-24 -- re-scoped, not closed. The title claimed the ApplicationSet, which "
    "INFRA-1636 owns; this ticket's own description already says 'Depends on INFRA-1636'. On the "
    "board the two read as the same work.\n\n"
    "THIS ticket is now the Git CREDENTIAL only. op-usxpress-prod has the platform half "
    "(ecr-credentials, app-namespaces, app-risingwave) and no credential, so nothing can be "
    "delivered there.\n\n"
    "Use a repository DEPLOY KEY, as proven end to end on op-usxpress-qa on 2026-08-20 "
    "(INFRA-1647). Do NOT wait for the org GitHub App: that is INFRA-1660, it needs variant-inc "
    "owner rights nobody on this team has, and a deploy key is repo-owned, does not expire and "
    "survives offboarding -- it satisfies 'no CI/CD tied to any one person' just as well.\n\n"
    "⚠️ op-prod manifests are copies and still carry DEV role ARNs in places. Diff before wiring."),

 "INFRA-1636": (
    "NOTE 2026-08-24. INFRA-1650 has been re-scoped to the Git credential only; this ticket owns "
    "the ApplicationSet, and 1650 depends on it. The 'NO automated sync' requirement is the "
    "load-bearing part: a prod Application must appear and sync only when a human triggers it."),

 "INFRA-1625": (
    "DECISION 2026-08-24 -- INFRA-1649 is closed as a duplicate of this ticket. Both describe the "
    "same defect on manhattan-dl-handler: AADSTS700213, where the OIDC subject depends on the "
    "TRIGGER rather than the branch (a pull_request run presents repo:org/repo:pull_request, "
    "while push and workflow_dispatch present repo:org/repo:ref:refs/heads/<branch>), which is "
    "why re-running sometimes helps and sometimes does not. Scoping the federated credentials to "
    "GitHub ENVIRONMENTS -- this ticket's fix -- is exactly what removes the need to register "
    "each branch, so 1649 has no work of its own.\n\n"
    "OCCURRENCES CARRIED OVER FROM 1649, so the frequency is not lost: 2026-07-21 (Charlie "
    "Wallace, blocked ahead of 2pm Manhattan testing, master and alt-load-and-driver), "
    "2026-08-11 (whitelistFix), 2026-08-19 (addCodesAndUpdateCols), and at least once before. "
    "Four in five weeks.\n\n"
    "⚠️ BLOCKED ON AZURE ACCESS, and this needs recording rather than sitting as TO DO. Editing "
    "federated identity credentials on the app registration requires rights on the Azure tenant "
    "that dare-x does not have. This is not platform work that is merely unstarted -- it cannot "
    "be started by its current assignee. Reassign to someone with the tenant, or get the access, "
    "before it is carried into another sprint.\n\n"
    "The procedure is written up: .claude/skills/azure-oidc-federation/"),

 "INFRA-1649": (
    "CLOSED 2026-08-24 as a duplicate of INFRA-1625.\n\n"
    "Same defect, same root cause, same fix. 1625 carries the incident history including the two "
    "occurrences recorded here (whitelistFix 2026-08-11, addCodesAndUpdateCols 2026-08-19) and "
    "the 2026-07-21 incident, and its fix -- scoping the federated credentials to GitHub "
    "environments rather than branches -- is what makes per-branch registration unnecessary. "
    "There is no work in this ticket that 1625 does not cover.\n\n"
    "Closed as duplicate, not as done: the defect is still live and still blocked on Azure "
    "access. Follow INFRA-1625."),

 "INFRA-1659": (
    "DECISION REQUIRED 2026-08-24 -- this ticket and INFRA-1627 are NOT duplicates, and that is "
    "the problem. They are two DIFFERENT delivery architectures for the same cluster:\n\n"
    "  INFRA-1627 (Steve Duck): SMTP relay -> Grafana alerting -> Freshservice. It is the stated "
    "prerequisite for extending INFRA-1588 (Idris) to on-prem, and it mirrors what cloud already "
    "does.\n"
    "  INFRA-1659 (this): Prometheus -> Alertmanager -> somewhere.\n\n"
    "Building both gives op-usxpress-dev two alerting pipelines and two places to look, which is "
    "how an on-call rota starts missing things. ONE of these has to become the path, and the "
    "other has to become a feeder into it.\n\n"
    "RECOMMENDATION: follow cloud. Grafana -> Freshservice is already the delivery path the "
    "organisation uses (INFRA-1588, INFRA-1593), so on-prem should not invent a second one. That "
    "makes INFRA-1627 the dependency and re-scopes THIS ticket from 'stand up Alertmanager' to "
    "'get Prometheus alerts into the Grafana/Freshservice path' -- which may still mean an "
    "Alertmanager, but as a component of that path rather than a parallel one.\n\n"
    "This is a design decision across three people (Steve owns 1627, Idris owns 1588), so it is "
    "NOT unblocked by a config change and should not be treated as ready work.\n\n"
    "⚠️ AND IT IS NOT READY REGARDLESS: INFRA-1658 found that delivering today would page "
    "immediately for five alerts that are not true (Talos control-plane rules firing critical "
    "since cluster build) and eleven that finished in June (stale Job objects). Those must be "
    "cleared first or the channel is trained to be ignored in its first week.\n\n"
    "One thing that must survive into whatever path is chosen: Watchdog. It fires continuously "
    "by design as a dead-man's switch and needs a receiver that alerts on its ABSENCE."),

 "INFRA-1627": (
    "NOTE 2026-08-24 -- overlaps INFRA-1659, which proposes a second and different delivery path "
    "for the same cluster (Prometheus -> Alertmanager). See the decision recorded on 1659: the "
    "recommendation is that on-prem follows cloud's Grafana -> Freshservice path, which makes "
    "THIS ticket the dependency and re-scopes 1659 to feeding into it.\n\n"
    "Context that was not available when this was filed on 2026-07-27: op-usxpress-dev currently "
    "has 55 firing alerts and no delivery of any kind. Prometheus' own "
    "PrometheusNotConnectedToAlertmanagers has been firing since 2026-06-24. The rules are good; "
    "nothing carries them.\n\n"
    "Before email is switched on, INFRA-1658's triage must be actioned -- five of the 55 are "
    "Talos false positives firing at critical severity since cluster build, and eleven refer to "
    "Jobs that failed in June and no longer run."),
}

CLOSE = ["INFRA-1649"]


def main():
    print(f"== decisions on 1625/1636/1649/1650/1627/1659  [{'GO' if GO else 'DRY RUN'}]\n")
    m.preflight()

    for key, new in RETITLE.items():
        s, body = m.api("GET", f"/rest/api/3/issue/{key}?fields=summary")
        cur = body.get("fields", {}).get("summary", "") if s == 200 else "?"
        print(f"  retitle {key}\n    was: {cur}\n    now: {new}")
        if GO:
            s, r = m.api("PUT", f"/rest/api/3/issue/{key}", {"fields": {"summary": new}})
            print(f"    {'OK' if s in (200, 204) else f'FAIL {s} {r}'}")

    print()
    for key in ("INFRA-1650", "INFRA-1636", "INFRA-1625", "INFRA-1649", "INFRA-1659", "INFRA-1627"):
        m.do_comment(key, COMMENTS[key])

    print()
    for key in CLOSE:
        m.do_close(key)

    if not GO:
        print("\nDry run. Re-run with --go.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
