#!/usr/bin/env python3
"""Close INFRA-1643 with the completed review, and file the boundary finding.

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
    ("INFRA-1643",
     "REVIEW COMPLETE 2026-08-20. Swept every repository in 064859874041 across both regions "
     "with scripts/audit-ecr-policies.sh.\n\n"
     "                         us-east-2   us-east-1   total\n"
     "  repositories                 497          20     517\n"
     "  write to org o-yza5l1xhrc    495          20     515   (99.6%)\n"
     "  write to named accounts        0           0       0\n"
     "  read-only, correctly scoped    1           0       1\n"
     "  no policy at all               1           0       1\n"
     "  IMMUTABLE tags                 5           2       7   (1.4%)\n"
     "  scanOnPush enabled            51          16      67   (13%)\n\n"
     "There is also NO registry-level permissions policy -- get-registry-policy returns empty "
     "in both regions -- so authorisation is entirely per-repository across all 517.\n\n"
     "I FILED THIS TICKET'S PREMISE WRONG AND THE SWEEP CORRECTS IT. On 2026-08-20 I recorded "
     "lazy/api as a repository not to model new policies on, because it grants PutImage, "
     "InitiateLayerUpload, UploadLayerPart and CompleteLayerUpload to every principal in the "
     "org. That was reasoning from one sample. lazy/api is not an outlier -- it is the "
     "template. The finding is not 'one repository is loose', it is 'the shared registry has "
     "no write boundary between accounts'.\n\n"
     "The single read-only repository is risingwave/etl-pipeline, created this morning for the "
     "on-prem delivery path (INFRA-1633). The single policy-less one is usxpress/playright-base "
     "-- a typo'd repository that sits beside the real usxpress/playwright-base and was never "
     "wired up. It is unreadable cross-account, silently; worth deleting rather than fixing.\n\n"
     "ON-PREM IS INSULATED, BY ACCIDENT. require-image-digest went to Enforce on the op-qa app "
     "namespaces this morning (INFRA-1640) and the on-prem path promotes by digest, so a "
     "repointed tag cannot reach those workloads. That control exists because of the CI/CD "
     "work, not because anyone assessed this. THE EKS FLEET HAS NO EQUIVALENT CONTROL THAT I "
     "HAVE VERIFIED, and that is where most of these 517 repositories are consumed.\n\n"
     "Remediation is NOT in this ticket: 515 policy changes across two regions, with no "
     "Terraform anywhere in the org to change them in (aws_ecr_repository appears once, in an "
     "interview sandbox), and narrowing the grants will break any build relying on the "
     "org-wide write -- which nobody has enumerated. Filed separately.\n\n"
     "Full review: wip/onprem-app-cicd/ECR-REGISTRY-REVIEW-2026-08-20.md. Re-runnable: "
     "scripts/audit-ecr-policies.sh --profile infra-common --region us-east-2 --summary"),
]

CREATE = [
    {"summary": "Shared ECR registry has no write boundary: 515 of 517 repositories grant push "
                "to every account in the org",
     "desc":
        "Found by the INFRA-1643 review, 2026-08-20. Swept with "
        "scripts/audit-ecr-policies.sh across both regions of 064859874041.\n\n"
        "515 of 517 repositories grant ecr:PutImage, ecr:InitiateLayerUpload, "
        "ecr:UploadLayerPart and ecr:CompleteLayerUpload to any principal in org "
        "o-yza5l1xhrc. There is no registry-level policy, so there is no boundary above them "
        "either. 7 repositories of 517 use IMMUTABLE tags.\n\n"
        "WHAT THAT MEANS CONCRETELY: any principal in any account in the organisation can "
        "replace the contents of any image the fleet runs, by pushing over a mutable tag. No "
        "deletion, no error, no event in the consuming cluster -- the same tag simply resolves "
        "to different bytes on the next pull. Image scanning would not catch it either; "
        "scanOnPush is enabled on 13%.\n\n"
        "EXPOSURE IS UNEVEN:\n"
        "  On-prem (op-usxpress-*) is insulated. require-image-digest is Enforce on the app "
        "namespaces (INFRA-1640) and the delivery path promotes by digest, so a repointed tag "
        "cannot reach those workloads. This was not a deliberate mitigation -- it landed for "
        "CI/CD reasons the same morning.\n"
        "  The EKS fleet is where most of these 517 repositories are actually consumed, and I "
        "have verified NO equivalent control there. That needs checking first, and it is the "
        "part that decides how urgent this is.\n\n"
        "WHY THIS IS NOT A PR:\n"
        "  1. No IaC. aws_ecr_repository appears exactly once in the whole variant-inc org, in "
        "an interview sandbox. All 517 policies were applied by hand or by an unidentified "
        "pipeline. There is nowhere to make a fleet-wide change. Depends on the ECR Terraform "
        "bootstrap (INFRA-1651).\n"
        "  2. Narrowing the grants breaks any build that relies on the org-wide write, and "
        "nobody has enumerated which builds those are. Needs CloudTrail on ecr:PutImage to "
        "establish who actually pushes where before anything is tightened.\n\n"
        "SUGGESTED SEQUENCE, smallest useful step first:\n"
        "  a. Verify whether the EKS fleet admits non-digest images. If it does, that is the "
        "real finding and it changes the priority of everything below.\n"
        "  b. CloudTrail ecr:PutImage for 30 days -> who pushes to what, by account.\n"
        "  c. Set IMMUTABLE on repositories the fleet runs from. Cheap, non-breaking for "
        "pushes, and removes the silent-repoint property.\n"
        "  d. Then narrow the write grants, per repository, from the CloudTrail evidence, "
        "through the IaC from INFRA-1651.\n\n"
        "Also: delete usxpress/playright-base (typo of usxpress/playwright-base, no policy, "
        "unreadable cross-account, never wired up).\n\n"
        "NEEDS A CLOUD-PLATFORM OWNER AND PROBABLY A SECURITY CONVERSATION. This is not an "
        "on-prem ticket -- it is filed from on-prem work because that is where it surfaced. "
        "Evidence: wip/onprem-app-cicd/ECR-REGISTRY-REVIEW-2026-08-20.md.",
     "labels": ["ecr", "security", "platform"]},
]


def main():
    print(f"== close-1643-file-ecr-boundary  [{'EXECUTING' if m.GO else 'DRY RUN (pass --go)'}]\n")
    m.preflight()
    for issue, comment in CLOSE:
        print(issue)
        m.do_comment(issue, comment)
        m.do_close(issue)
    print()
    for spec in CREATE:
        m.do_create(spec)


if __name__ == "__main__":
    main()
