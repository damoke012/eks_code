#!/usr/bin/env python3
"""Re-scope and close INFRA-1638, and file what it uncovered.

INFRA-1638 says "extend AWS SSO cluster access to op-usxpress-dev and
op-usxpress-prod". Nobody can log in yet -- the kube-apiserver webhook flag is a
separate repo and a separate promotion -- so closing it as written would be a
close about the step NEXT to the one that matters, which is the exact failure
this sprint spent the day cataloguing.

So: re-scope 1638 to what was actually delivered and verified (the authenticator
and RBAC manifests, delivered by Flux, on dev and prod), close it on evidence,
and file the remainder as three tickets. Two of those are risks that existed
before today and were found by accident:

  * QA's kube-apiserver flag lives on an UNMERGED iaac-talos branch. Redeploying
    QA from master removes its SSO silently.
  * op-usxpress-prod appears NOWHERE in iaac-talos on any branch, so prod's Talos
    machine config has no known IaC home.

THE CLOSE IS GATED: 1638 closes only if BOTH prod PRs are merged, checked through
the GitHub API. Dev is already verified live.

DRY-RUN BY DEFAULT. Pass --go.
Auth:  read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo
       gh auth status      # for the PR gate
Run from WSL against corporate GHE (CLAUDE.md rule 10).
"""
import importlib.util, json, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("closer", os.path.join(HERE, "close-sprint3-tickets.py"))
m = importlib.util.module_from_spec(spec)
_argv = sys.argv[:]; sys.argv = ["x"]
spec.loader.exec_module(m)
sys.argv = _argv
# m.GO is what do_comment/do_close/do_create read. Setting only a local GO means
# --go is accepted and silently does nothing -- that shipped twice today.
m.GO = "--go" in sys.argv
GO = m.GO

PRS = [("variant-inc/iaac-talos-flux-platform", 125),
       ("variant-inc/iaac-talos-flux-cluster", 37)]

NEW_SUMMARY = ("Deploy aws-iam-authenticator + platform RBAC to op-usxpress-dev and "
               "op-usxpress-prod (apiserver flag is INFRA-1661)")

CLOSE_1638 = (
    "RE-SCOPED AND CLOSED 2026-08-24.\n\n"
    "This ticket was filed as \"extend AWS SSO cluster access\". Nobody can log in yet, so "
    "closing it as written would claim something untrue. Re-scoped to what was delivered and "
    "verified -- the authenticator and RBAC manifests, delivered by Flux -- with the remaining "
    "work filed as INFRA-1661/1662/1663.\n\n"
    "DELIVERED, BOTH REPOS, BOTH CLUSTERS:\n"
    "  iaac-talos-flux-platform  #124 -> op-dev (MERGED), #125 -> op-prod\n"
    "  iaac-talos-flux-cluster   #36 -> clusters/bm-dev (MERGED), #37 -> clusters/op-usxpress-prod\n"
    "Neither cluster had infrastructure/rbac or infrastructure/aws-iam-authenticator, and neither "
    "had a Flux Kustomization for either. QA has had both since 2026-07-28 and IS fully GitOps -- "
    "wired at clusters/op-usxpress-qa/flux-system/infra.yaml:751. An earlier claim in this "
    "investigation that QA had been hand-applied was wrong; the grep behind it was run against "
    "the wrong repository.\n\n"
    "VERIFIED LIVE ON op-usxpress-dev, 2026-08-24 20:04 UTC -- not by Ready=True, which only says "
    "the manifests applied:\n"
    "  * 3/3 DaemonSet pods Running, RESTARTS 0, one per control plane (talos-cp-op-dev-1/2/3 at "
    "10.10.82.29 / .181 / .179). The liveness probe carries host: 127.0.0.1; without it the "
    "kubelet probes the node IP and the pod CrashLoops (~140 restarts/8h when this was first hit).\n"
    "  * kube-system/aws-auth carries "
    "arn:aws:iam::700736442855:role/AWSReservedSSO_usx-on-prem-admins_b7447c115978d407, PATH "
    "STRIPPED.\n"
    "  * clusterrolebinding/onprem-platform-admins -> group onprem-platform-admins -> cluster-admin.\n"
    "  * All three servers logged 'starting mapper \"EKSConfigMap\"', 'Received aws-auth watch "
    "event', and 'listening on 127.0.0.1:21362'.\n\n"
    "THE ARN IS PER-ACCOUNT AND WAS READ BACK, NEVER COPIED. usx-on-prem-admins is provisioned to "
    "all three accounts and AWS generates a different suffix in each: dev b7447c115978d407, qa "
    "8c7f139e431625e0, prod 837df2a43495aaf1. A copied ARN does NOT error -- the caller "
    "authenticates as system:anonymous and every request returns forbidden, which reads exactly "
    "like an RBAC bug. Same for the path: list-roles returns "
    "role/aws-reserved/sso.amazonaws.com/... and the authenticator canonicalises WITHOUT it.\n\n"
    "rbac is delivered first and the authenticator dependsOn it. aws-auth maps the role onto a "
    "group that rbac binds; reversed, the first person to log in authenticates correctly and can "
    "do nothing. op-usxpress-qa does not declare that dependency -- worth adding there.\n\n"
    "EXPLICITLY NOT DONE, AND WHY THIS IS NOT A LOGIN YET: kube-apiserver has no "
    "--authentication-token-webhook-config-file, so nothing consults any of the above. It is "
    "inert and entirely green, which is the combination worth distrusting. That flag is Talos "
    "machine config in variant-inc/iaac-talos, promoted through Octopus only (CLAUDE.md rule 1), "
    "and is now INFRA-1661.\n\n"
    "Full record: wip/onprem-sso/INFRA-1638-dev-authenticator-live.md"
)

CREATE = [
 {"summary": "Enable the kube-apiserver aws-iam-authenticator webhook (iaac-talos) — dev first, then prod",
  "labels": ["onprem", "sso", "talos"],
  "desc": (
    "INFRA-1638 delivered the authenticator DaemonSet, kube-system/aws-auth and the platform "
    "RBAC to op-usxpress-dev (live, verified) and op-usxpress-prod (PRs #125/#37). None of it is "
    "consulted until kube-apiserver is given "
    "--authentication-token-webhook-config-file. Until then there is no SSO login on either "
    "cluster.\n\n"
    "THE WORK ALREADY EXISTS AND IS NOT MERGED. variant-inc/iaac-talos branch "
    "feat/aws-iam-authenticator (head ca5479f) carries it: apiserver_extra_args and "
    "apiserver_extra_volumes in deploy/terraform/modules/talos/main.tf, gated on "
    "var.enable_aws_iam_authenticator, plus one line in deploy/terraform/envs/qa.tfvars. The "
    "branch is 4 commits behind master, so this is a rebase and a careful read, not a "
    "fast-forward -- and it is the module that generates EVERY cluster's machine config.\n\n"
    "THE FLAG TAKES THE HOST PATH: /var/lib/aws-iam-authenticator/kubeconfig.yaml. Three paths "
    "appear in this system and only that one is right. The init container's log says "
    "/etc/kubernetes/aws-iam-authenticator/kubeconfig.yaml -- upstream's generic advice, wrong on "
    "Talos where /etc/kubernetes is OS-managed. The server container's log says "
    "/var/aws-iam-authenticator/kubeconfig.yaml -- where it wrote the file INSIDE its own "
    "container. The branch says so itself: '# HOST path. The authenticator's own log prints the "
    "in-container path; not this one.'\n\n"
    "ORDERING, from the variable's own description: kube-apiserver will NOT START if the webhook "
    "config file is missing. The DaemonSet must already be Running and have written the file on "
    "EVERY control-plane node before this is set true. x509 auth is unaffected either way, so the "
    "admin kubeconfig remains the way back in. op-usxpress-dev SATISFIES this precondition as of "
    "2026-08-24 -- 3/3 pods, all CPs, 0 restarts.\n\n"
    "Do not split the apiServer patch per feature. The module deliberately assembles ONE patch "
    "from a merged map, because two patches both setting extraArgs would depend on Talos merging "
    "rather than replacing them -- and if it replaces, IRSA silently breaks.\n\n"
    "AC:\n"
    "  1. feat/aws-iam-authenticator rebased on master and merged.\n"
    "  2. enable_aws_iam_authenticator = true in dev.tfvars; promoted via OCTOPUS ONLY.\n"
    "  3. On op-usxpress-dev: `aws sso login --profile usx-dev` then `kubectl auth whoami` "
    "returns sso:<email> in group onprem-platform-admins. THIS is the acceptance -- a wrong ARN "
    "produces forbidden on everything rather than an error, so 'the pods are up' proves nothing.\n"
    "  4. Prod only after INFRA-1663 answers where prod's machine config lives, and after "
    "scripts/breakglass-prod-kubeconfig.sh is confirmed to produce a working kubeconfig.\n\n"
    "Blocks: nothing. Blocked by: INFRA-1662 (same branch) for QA; INFRA-1663 for prod.")},

 {"summary": "RISK: op-usxpress-qa's apiserver SSO flag lives on an unmerged iaac-talos branch",
  "labels": ["onprem", "sso", "talos", "risk"],
  "desc": (
    "Found 2026-08-24 while doing INFRA-1638. NOT introduced by that work -- this has been true "
    "since QA's SSO went live on 2026-07-28.\n\n"
    "op-usxpress-qa has had working AWS SSO login for four weeks. The kube-apiserver flag that "
    "makes it work is in variant-inc/iaac-talos on branch feat/aws-iam-authenticator, together "
    "with `enable_aws_iam_authenticator = true` in deploy/terraform/envs/qa.tfvars.\n\n"
    "  git branch -r --merged origin/master | grep -c aws-iam-authenticator  ->  0\n"
    "  grep -rn 'authentication-token-webhook-config-file' on master          ->  nothing\n\n"
    "So the running configuration of a cluster people use every day is not in the mainline. "
    "REDEPLOYING QA FROM MASTER WOULD REMOVE ITS SSO -- silently, because the flag would simply "
    "not be in the generated machine config, and every status field would stay green. x509 "
    "break-glass would still work, so the failure would present as 'SSO stopped working' with no "
    "obvious cause and no recent change to point at.\n\n"
    "This is the same family as INFRA-1642 (running state and mainline disagree) and "
    "octopus-green-but-no-apply: nothing in the pipeline reports the divergence.\n\n"
    "Fix: merging feat/aws-iam-authenticator (INFRA-1661) resolves this as a side effect. Filed "
    "separately because the RISK exists now and should be visible even if 1661 is deferred, and "
    "because it deserves the question of whether anything ELSE is running on an unmerged branch.\n\n"
    "AC: the flag is on master, and a QA deploy from master is confirmed to preserve SSO.")},

 {"summary": "op-usxpress-prod has no Talos machine config in iaac-talos — no prod.tfvars, no mention on any branch",
  "labels": ["onprem", "talos", "iac"],
  "desc": (
    "Found 2026-08-24 while planning INFRA-1638's prod half.\n\n"
    "  deploy/terraform/envs/  contains only dev.tfvars and qa.tfvars\n"
    "  grep -rn 'op-usxpress-prod' --include='*.tf' --include='*.tfvars' --include='*.yaml'  -> nothing\n"
    "  git log --all --oneline -S 'op-usxpress-prod' -- deploy/                              -> nothing\n"
    "  git branch -r | grep -i prod                                                          -> nothing\n\n"
    "op-usxpress-prod (API 10.10.82.52) was stood up under INFRA-1589/1621 and its platform stack "
    "fully reconciled on 2026-07-29, so SOMETHING generated its machine config. It is not this "
    "repository's deploy tree, on any branch, ever.\n\n"
    "HYPOTHESIS, NOT A FINDING: prod's variables are supplied by Octopus rather than a repo "
    "tfvars file, which would fit onprem-deploy-via-octopus and octopus-green-but-no-apply "
    "(TfApply=false everywhere but production). VERIFY IN OCTOPUS. Do not add a prod.tfvars on "
    "the assumption that the pattern matches dev and QA -- if prod is driven from Octopus "
    "variables, a repo tfvars would be either ignored or a second source of truth, and both are "
    "worse than the current state.\n\n"
    "Why it matters now: INFRA-1661 needs somewhere to set enable_aws_iam_authenticator for prod, "
    "and there is no such place. More broadly, a production cluster whose machine config has no "
    "known IaC home cannot be rebuilt from source, which is the property the whole on-prem "
    "programme is meant to have.\n\n"
    "AC: written answer to 'where does op-usxpress-prod's Talos machine config come from, and how "
    "would we rebuild the cluster from it', with the source named and reachable.")},
]


def prs_merged():
    """Gate the close on the prod PRs actually being merged, via the API."""
    if not shutil.which("gh"):
        print("  !! gh not on PATH -- cannot verify the prod PRs")
        return False
    ok = True
    for repo, num in PRS:
        r = subprocess.run(["gh", "pr", "view", str(num), "--repo", repo, "--json", "state,mergedAt"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(f"  !! {repo}#{num}: {r.stderr.strip()[:120]}")
            ok = False; continue
        d = json.loads(r.stdout)
        state = d.get("state")
        print(f"  {repo}#{num}: {state} {d.get('mergedAt') or ''}")
        if state != "MERGED":
            ok = False
    return ok


def main():
    print(f"== INFRA-1638 close + Talos gap tickets  [{'GO' if GO else 'DRY RUN'}]\n")
    m.preflight()

    print("-- filing what INFRA-1638 uncovered --")
    for spec_ in CREATE:
        m.do_create(spec_)

    print("\n-- INFRA-1638: verifying the prod PRs before closing --")
    if not prs_merged():
        print("\n!! NOT closing INFRA-1638 -- the prod PRs are not merged.")
        print("   Merge #125 (platform) then #37 (cluster), then re-run.")
        print("   The tickets above are filed either way; they do not depend on it.")
        return 1

    print("\n  both prod PRs merged -- re-scoping and closing")
    s, body = m.api("GET", "/rest/api/3/issue/INFRA-1638?fields=summary")
    if s == 200:
        print(f"    was: {body.get('fields', {}).get('summary', '?')}")
    print(f"    now: {NEW_SUMMARY}")
    if GO:
        s, r = m.api("PUT", "/rest/api/3/issue/INFRA-1638", {"fields": {"summary": NEW_SUMMARY}})
        print(f"    retitle: {'OK' if s in (200, 204) else f'FAIL {s} {r}'}")
    m.do_comment("INFRA-1638", CLOSE_1638)
    m.do_close("INFRA-1638")

    if not GO:
        print("\nDry run. Re-run with --go.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
