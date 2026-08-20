#!/usr/bin/env python3
"""Close INFRA-1533 and INFRA-1646, which are done as of 2026-08-20.

DRY-RUN BY DEFAULT. Pass --go to execute.  Auth: export ATLASSIAN_TOKEN=...
"""
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location(
    "closer", os.path.join(os.path.dirname(os.path.abspath(__file__)), "close-sprint3-tickets.py"))
m = importlib.util.module_from_spec(spec)
_argv = sys.argv[:]; sys.argv = ["x"]
spec.loader.exec_module(m)
sys.argv = _argv
m.GO = "--go" in sys.argv

CLOSE = [
    ("INFRA-1533",
     "Closing 2026-08-20. Every item this ticket lists as scope is validated: Argo CD repo "
     "sync against iaac-risingwave-onprem, the ExternalSecret retrieving the Git auth key from "
     "AWS Secrets Manager, the repo secret templated and syncing in-cluster, RisingWave live "
     "with the Application Healthy, and RW user auth end to end. The only remaining scope was "
     "'continue monitoring', which is not a deliverable. Superseded in practice on 2026-08-20: "
     "Argo CD on op-usxpress-qa now delivers an application end to end (INFRA-1648), which is a "
     "stronger result than the dev-only validation this ticket asked for."),

    ("INFRA-1646",
     "DONE 2026-08-20: scripts/check-foreign-cluster-ids.sh. Give it a platform checkout and a "
     "target branch and it scans for the other clusters' account IDs, OIDC issuers, API node "
     "addresses and DNS suffixes, exiting non-zero on a hit. --diff <base-ref> limits it to "
     "changed files, which is the pre-merge form. The shared ECR account 064859874041 is "
     "deliberately not flagged -- every cluster pulls from it.\n\n"
     "Tested both directions: the op-qa argocd-config directory scans clean as op-qa, and the "
     "same directory scanned as op-prod reports the op-usxpress-qa Secrets Manager path -- the "
     "exact defect shape this ticket was filed for.\n\n"
     "Wired into PUSH-PATHS.md as a step before every platform PR and into ONPREM-CICD.md 4.2c. "
     "Companion check for app overlays: scripts/verify-overlay-endpoints.sh resolves every "
     "*.svc.cluster.local name against the target cluster (it caught a dev postgres service "
     "name in the QA overlay on 2026-08-20, which was instance five of this class)."),
]

def main():
    print(f"== close-1533-1646  [{'EXECUTING' if m.GO else 'DRY RUN (pass --go)'}]\n")
    m.preflight()
    for issue, comment in CLOSE:
        print(issue)
        m.do_comment(issue, comment)
        m.do_close(issue)

if __name__ == "__main__":
    main()
