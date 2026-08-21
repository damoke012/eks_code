#!/usr/bin/env python3
"""Correct INFRA-1640 and INFRA-1641 (fixed on one cluster of three), and file
the auto-merge finding.

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

COMMENT = [
    ("INFRA-1640",
     "CORRECTION 2026-08-21: I closed this having flipped ONE cluster of three. op-dev and "
     "op-prod were still Audit. Neither the ticket nor my closure said 'on op-qa', and the "
     "closure did not check the other branches.\n\n"
     "Now Enforce on all three: op-qa (#100), op-dev (#106), op-prod (#107). Diffs verified as "
     "Audit -> Enforce only before shipping.\n\n"
     "Two things the closure also overstated:\n"
     "  Both policies carry allowExistingViolations: true. Enforce gates NEW admissions; it "
     "does not evict or block updates to resources that already violated. I wrote 'they now "
     "reject at admission', which is true only for new resources.\n"
     "  On op-dev and op-prod this is currently INERT. The policies match namespaceSelector "
     "platform.usxpress.io/delivery=argocd; app-risingwave is empty on both -- dev iterates via "
     "the in-cluster ARC runner, and prod has no ApplicationSet or Git credential yet. The "
     "guardrail is deliberately placed before the first delivered app rather than after, but it "
     "mitigates nothing today.\n\n"
     "Found by scripts/check-wip-matches-branch.sh, which reports every draft in the notes repo "
     "that disagrees with what a cluster branch ships."),

    ("INFRA-1641",
     "CORRECTION 2026-08-21: same shape as INFRA-1640 -- I closed this having hardened ONE "
     "cluster of three. op-dev and op-prod still carried every defect: */5 schedule commented "
     "'every 6 hours', unpinned aws-cli:latest, init Job at ttl 300 relooping perpetually, the "
     "sync script duplicated between the two workloads, and the namespace loop that printed an "
     "HTTP code and carried on. Ported as #108 (dev), #109 (prod), #110 (qa).\n\n"
     "THE PORT THEN BROKE op-dev, AND THAT IS THE USEFUL PART.\n"
     "A Job's pod template is immutable. Changing the init Job's image, command and TTL makes "
     "Flux's SERVER-SIDE DRY RUN fail with 'field is immutable', and the whole Kustomization "
     "aborts -- so none of the other changes in that directory apply either. op-qa escaped this "
     "in #103 only because ttl was 300 and the Job happened to be absent at that moment. Timing, "
     "not correctness.\n\n"
     "I added kustomize.toolkit.fluxcd.io/force -- with the value \"true\". Flux's force "
     "annotation takes enabled/disabled and SILENTLY IGNORES anything else. No warning, no "
     "event. op-dev's ecr-credentials went Ready=False and stayed there until corrected to "
     "\"enabled\" (#111 dev, #112 qa, #113 prod). Verified on op-dev: Ready=True, schedule "
     "0 */6 * * *, concurrencyPolicy Forbid, init Job ttl 86400 and recreated.\n\n"
     "Still open on all three: the token probe logs 'WARNING: could not verify the token "
     "(ecr:DescribeRegistry may not be granted)'. Granting ecr:DescribeRegistry on each "
     "cluster's ecr-credentials-sync role turns that warning into a real gate."),
]

CREATE = [
    {"summary": "iaac-talos-flux-platform auto-merges on green, so every PR is an immediate "
                "deploy — including to op-prod",
     "desc":
        "Found 2026-08-21 while sequencing a change across clusters.\n\n"
        "I intended to ship a change to op-dev, verify it, and only then ship it to op-prod. "
        "That sequencing is not available: the repository auto-merges a PR as soon as checks "
        "pass, so PR #109 landed on op-prod before op-dev had proven anything. It carried a "
        "defect -- kustomize.toolkit.fluxcd.io/force: \"true\" instead of \"enabled\" -- which "
        "put the ecr-credentials Kustomization into Ready=False on whichever cluster received "
        "it. On op-dev that was observed and corrected in minutes. On op-prod it was merged "
        "before anyone could look.\n\n"
        "The cost today was low: ecr-credentials failing to reconcile does not stop the existing "
        "CronJob from running, and the fix followed within the hour (#113). The point is that "
        "nobody chose this. 'Verify on dev, then promote' is how we describe the process and it "
        "is not what the tooling does.\n\n"
        "OPTIONS, roughly in order of effort:\n"
        "  a. Branch protection on op-prod requiring an approving review. Cheapest, and makes "
        "the prod merge a deliberate act.\n"
        "  b. Disable auto-merge on op-prod only, keeping dev and qa fast.\n"
        "  c. Suspend the Flux Kustomization on prod during a staged change and resume "
        "deliberately. Heavier, and easy to forget resumed.\n"
        "  d. Accept it, and require that any PR targeting op-prod has already been merged and "
        "verified on op-dev or op-qa -- enforced by a check rather than by intent.\n\n"
        "My preference is (a) plus (d): review required on prod, and a check that the same "
        "change is already live somewhere else. Needs whoever owns the repo's settings.\n\n"
        "Related: INFRA-1638 -- prod cannot currently be verified without break-glass, which is "
        "what made this uncomfortable rather than routine.",
     "labels": ["onprem", "process", "prod"]},
]


def main():
    print(f"== comment-1640-1641-fleet  [{'EXECUTING' if m.GO else 'DRY RUN (pass --go)'}]\n")
    m.preflight()
    for issue, body in COMMENT:
        print(issue); m.do_comment(issue, body)
    print()
    for spec in CREATE:
        m.do_create(spec)


if __name__ == "__main__":
    main()
