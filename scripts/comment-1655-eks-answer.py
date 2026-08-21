#!/usr/bin/env python3
"""Answer INFRA-1655 step (a) and hand it to a cloud-platform owner.

DRY-RUN BY DEFAULT. Pass --go to execute. Does NOT close.
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
 "STEP (a) ANSWERED 2026-08-21, and the answer is the bad one. The EKS fleet is exposed.\n\n"
 "                              usxpress-dev   qa-one   usxpress-prod\n"
 "  container references              2271      2169            3100\n"
 "  pinned by digest                   489       401             337  (11%)\n"
 "  referenced by TAG                 1782      1768            2763\n"
 "  tag refs into 064859874041         352       388             733\n\n"
 "ADMISSION CONTROL THAT COULD REQUIRE DIGESTS:\n"
 "  usxpress-prod  NONE. No Kyverno ClusterPolicy CRD and no image-related validating "
 "webhook of any kind.\n"
 "  usxpress-dev / qa-one  Kyverno is installed, but the only ClusterPolicy is "
 "docker-hub-ecr-pull-through-cache at Audit, which is not about digests.\n\n"
 "So 733 references in the PRODUCTION cluster resolve through mutable tags in a registry "
 "where 515 of 517 repositories grant push to every principal in org o-yza5l1xhrc "
 "(INFRA-1643). Any one of them can be moved to different content by a push, with no "
 "deletion, no error and no event in the cluster. 144 distinct repositories are involved, "
 "and none of the ones I could match are IMMUTABLE.\n\n"
 "This is a supply-chain exposure in production, not registry hygiene. It should be "
 "prioritised as such.\n\n"
 "THE ON-PREM CLUSTERS ARE NOT AFFECTED THE SAME WAY: require-image-digest is Enforce on "
 "op-usxpress-qa app namespaces (INFRA-1640) and the on-prem delivery path promotes by "
 "digest. That is currently the only digest enforcement anywhere in the estate, and it "
 "landed for CI/CD reasons rather than as a security control. op-dev and op-prod coverage "
 "is being checked separately and is on-prem's own ticket.\n\n"
 "NEEDS A CLOUD-PLATFORM OWNER. This was found from on-prem work and the on-prem team is "
 "not the right owner for remediating the EKS fleet or ~500 repository policies. Handing "
 "over rather than proposing a fix.\n\n"
 "RE-RUNNABLE EVIDENCE, both read-only:\n"
 "  scripts/check-image-provenance.sh --context usxpress-prod --kubeconfig ~/.kube/qa-one-eks.yaml\n"
 "  scripts/audit-ecr-policies.sh --profile infra-common --region us-east-2 --summary\n"
 "Review: wip/onprem-app-cicd/ECR-REGISTRY-REVIEW-2026-08-20.md"
)

def main():
    print(f"== comment-1655-eks-answer  [{'EXECUTING' if m.GO else 'DRY RUN (pass --go)'}]\n")
    m.preflight()
    print("INFRA-1655")
    m.do_comment("INFRA-1655", BODY)
    print("\n(not closed, not reassigned by script — hand it over by name)")

if __name__ == "__main__":
    main()
