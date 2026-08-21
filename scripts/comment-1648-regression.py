#!/usr/bin/env python3
"""Record on INFRA-1648 that the proven path regressed and was restored.

Comments only. The ticket stays Done -- the proof was real. What was wrong was
what the closure IMPLIED.

DRY-RUN BY DEFAULT. Pass --go.
Auth:  read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo
"""
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location(
    "closer", os.path.join(os.path.dirname(os.path.abspath(__file__)), "close-sprint3-tickets.py"))
m = importlib.util.module_from_spec(spec)
_argv = sys.argv[:]; sys.argv = ["x"]
spec.loader.exec_module(m)
sys.argv = _argv
m.GO = "--go" in sys.argv

BODY = (
 "REGRESSED AND RESTORED — recording this against the closure rather than reopening, because "
 "the proof was real and the fault was in what I took it to mean.\n\n"
 "TIMELINE\n"
 "  2026-08-20 16:26Z  smoke row lands in pipeline_applied. Path works. Ticket closed.\n"
 "  2026-08-20 16:58Z  last successful Argo CD sync, against "
 "ssh://git@github.com/variant-inc/risingwave-pipeline.git.\n"
 "  2026-08-20 ~19:30Z platform#100 merges and DELIVERY STOPS.\n"
 "  2026-08-21 ~14:00Z found while preparing to copy the same manifests to op-dev.\n"
 "  2026-08-21 ~14:30Z restored by platform#105. Verified sync=Synced.\n\n"
 "CAUSE. platform#100 was Kyverno Enforce plus the ApplicationSet retry limit. I built it by "
 "copying wip/onprem-app-cicd/platform/argocd-apps/applicationset-qa.yaml over the branch "
 "file. That copy still carried repoURL: https://; the ssh:// correction had been made on the "
 "branch and never back-ported. So a PR about admission policy silently reverted the Git URL.\n\n"
 "WHY IT WAS INVISIBLE FOR 18 HOURS. The credential is a deploy key -- secret-type: "
 "repository, matched on the EXACT url. https:// matches nothing, so Argo CD sends no "
 "credential, and GitHub answers an unauthenticated request for a private repo with "
 "'Repository not found' -- which reads like a deleted repository, not an auth failure. Argo "
 "CD showed sync=Unknown, health=Healthy, and operationState=Succeeded FROM THE PREVIOUS DAY. "
 "No alert, no failing pod, no red anywhere.\n\n"
 "WHAT THE CLOSURE SHOULD HAVE SAID. 'Proven end to end' described one execution at a point "
 "in time. It is not a property of the system, and I wrote it as though it were. A pipeline is "
 "proven by a check that can be re-run, not by a run.\n\n"
 "WHAT NOW EXISTS SO THIS CANNOT REPEAT SILENTLY\n"
 "  scripts/check-argocd-repo-credentials.sh --context <ctx>  -- matches every Application and "
 "ApplicationSet element against every credential using Argo CD's own rules (repository = "
 "exact, repo-creds = prefix), names the other-URL-form credential when one exists, and prints "
 "live comparison status so a stale Succeeded cannot hide a broken app. Validated red against "
 "this defect and green after the fix.\n"
 "  scripts/check-wip-matches-branch.sh <checkout> <branch>   -- reports every draft in the "
 "notes repo that disagrees with what the branch ships.\n"
 "  CLAUDE.md rule 7 -- the notes repo is not a staging area. Build platform PRs FROM the "
 "branch and read git diff origin/<base> in full, including hunks you did not intend."
)

def main():
    print(f"== comment-1648-regression  [{'EXECUTING' if m.GO else 'DRY RUN (pass --go)'}]\n")
    m.preflight()
    print("INFRA-1648")
    m.do_comment("INFRA-1648", BODY)
    print("\n(left Done deliberately — the proof happened; the implication was wrong)")

if __name__ == "__main__":
    main()
