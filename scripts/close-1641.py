#!/usr/bin/env python3
"""Close INFRA-1641, verified on op-usxpress-qa 2026-08-20.

DRY-RUN BY DEFAULT. Pass --go to execute.
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

CLOSE = [
    ("INFRA-1641",
     "DONE on op-usxpress-qa 2026-08-20, merged as iaac-talos-flux-platform#103 and verified by "
     "running the rewritten Job, not by the merge.\n\n"
     "FOUR DEFECTS, two of them comments describing behaviour the file did not have:\n"
     "  schedule: \"*/5 * * * *\"      commented \"Every 6 hours\"  -> 288 runs/day, each PUTting "
     "a Secret and PATCHing every ServiceAccount in every namespace. Now 0 */6 * * *.\n"
     "  ttlSecondsAfterFinished: 300  commented \"24h\"            -> Flux recreates the init Job "
     "the moment the TTL removes it, so it re-ran every few minutes forever beside the CronJob. "
     "Observed live 20:16Z: the init Job was Running 63s after a CronJob run had completed the "
     "identical work. Now 86400, so it re-runs about daily and keeps its bootstrap purpose.\n"
     "  image: aws-cli:latest, twice  -> now pinned to "
     "public.ecr.aws/aws-cli/aws-cli@sha256:9e94ede8b677fe5456a152fd6698a6726810160497882123bfd9dd40a5671d74, "
     "the digest the cluster was already running.\n"
     "  no concurrencyPolicy          -> now Forbid, with startingDeadlineSeconds: 600.\n\n"
     "TWO MORE FOUND WHILE IN THERE:\n"
     "  The sync script was duplicated VERBATIM between the CronJob and the init Job. Same shape "
     "as INFRA-1654 (two copies of one thing, one silently wrong). It now lives once, in a "
     "ConfigMap, mounted by both.\n"
     "  The namespace loop printed the HTTP code and carried on, so a namespace that rejected "
     "the write looked exactly like one that accepted it. It now counts failures and exits "
     "non-zero.\n\n"
     "VERIFIED by `kubectl create job --from=cronjob/ecr-credentials-sync` rather than waiting "
     "for the schedule: log clean, secret synced to all namespaces, and the pod's imageID "
     "confirms the digest. Kyverno was checked first -- require-image-digest and "
     "require-approved-registry are scoped by namespaceSelector "
     "platform.usxpress.io/delivery=argocd, so the Enforce flip earlier today did not and does "
     "not affect this namespace.\n\n"
     "FOLLOW-UP, NOT A BLOCKER: the new token probe logs\n"
     "  WARNING: could not verify the token (ecr:DescribeRegistry may not be granted).\n"
     "It is advisory by design. The first draft had it as a hard gate under `set -e`, which "
     "would have failed this run and every run after it, and the cluster would have lost its "
     "pull credential within 12h. Granting ecr:DescribeRegistry on "
     "op-usxpress-qa-ecr-credentials-sync would turn it into a real gate -- worth doing, since "
     "a token that decodes is not a token that works (INFRA-1633)."),
]


def main():
    print(f"== close-1641  [{'EXECUTING' if m.GO else 'DRY RUN (pass --go)'}]\n")
    m.preflight()
    for issue, comment in CLOSE:
        print(issue)
        m.do_comment(issue, comment)
        m.do_close(issue)


if __name__ == "__main__":
    main()
