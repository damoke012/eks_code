#!/usr/bin/env python3
"""Record the 2026-08-21 decisions on every open on-prem ticket, re-scope
INFRA-1642, take ownership of what turned out not to be blocked, and close what
is actually finished.

Four of the five tickets described as "blocked on another person" were blocked
on a PREFERENCE, not a person. The decisions are in
wip/onprem-app-cicd/DECISIONS-2026-08-21.md; this posts them where the work is.

INFRA-1656 is closed ONLY IF the branch protection it asks for can be PROVEN to
exist, via the GitHub API. A close that asserts its own acceptance criteria is
how INFRA-1640 and INFRA-1641 were wrongly closed last week.

DRY-RUN BY DEFAULT. Pass --go.
Auth:  read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo
       gh auth status          # for the INFRA-1656 verification only
"""
import importlib.util, json, os, shutil, subprocess, sys

spec = importlib.util.spec_from_file_location(
    "closer", os.path.join(os.path.dirname(os.path.abspath(__file__)), "close-sprint3-tickets.py"))
m = importlib.util.module_from_spec(spec)
_argv = sys.argv[:]; sys.argv = ["x"]
spec.loader.exec_module(m)
sys.argv = _argv
m.GO = "--go" in sys.argv
GO = m.GO

REPO = "variant-inc/iaac-talos-flux-platform"
DOC = "Full rationale, trade-offs and what each costs: wip/onprem-app-cicd/DECISIONS-2026-08-21.md"

# ---------------------------------------------------------------- decisions --
COMMENT = [
    ("INFRA-1636",
     "DECISION 2026-08-21 -- unblocked. This was waiting on an org-owned GitHub App, which "
     "needs variant-inc owner rights that dare-x does not have. It does not need to wait.\n\n"
     "Use a repository DEPLOY KEY, exactly as shipped on op-usxpress-qa in INFRA-1647 and "
     "proven end to end on 2026-08-20. A deploy key is repo-owned, does not expire, survives "
     "offboarding, and satisfies the 'no CI/CD tied to any one person' requirement just as well "
     "as an App. We are admin on the repositories, so we can add one without asking anyone.\n\n"
     "COST, stated plainly: a deploy key is PER REPOSITORY. One app, one key. The App's real "
     "advantage is one installation covering the whole org with short-lived tokens Argo CD "
     "renews itself. At two or three applications this is fine; at fifteen it is an "
     "administrative mess. So this is right now and wrong eventually -- the App is DEFERRED, "
     "not abandoned, and has its own ticket so it stops silently blocking others.\n\n"
     "This ticket does not close on a secret existing. It closes when an Application on "
     "op-usxpress-prod actually SYNCS -- PR #100 taught us that a credential can look present "
     "while sync=Unknown and operationState reads Succeeded from the previous day.\n\n" + DOC),

    ("INFRA-1650",
     "DECISION 2026-08-21 -- same as INFRA-1636: deploy key, not GitHub App. See that ticket "
     "and the decision record. No longer blocked on an org owner; this is ours to implement.\n\n"
     "Sequencing note: the credential lands first, the ApplicationSet second, and the "
     "ApplicationSet's repoURL MUST match the credential's URL form exactly. Argo CD matches a "
     "secret-type: repository credential on an EXACT url match -- ssh:// and https:// are not "
     "interchangeable. Reverting that one field is what broke op-qa delivery for 18 hours on "
     "2026-08-20 with every status field green.\n\n" + DOC),

    ("INFRA-1639",
     "DECISION 2026-08-21 -- unblocked, by changing the identity provider.\n\n"
     "This was scoped around an Entra app registration. Dare has no Azure access, so it has not "
     "moved since 2026-08-18 and would not have.\n\n"
     "Use AWS IAM Identity Center as the provider instead, through Argo CD's bundled Dex. We "
     "are admin in AWS. The identical model is already proven for CLUSTER access on "
     "op-usxpress-qa -- aws-iam-authenticator on the control plane, access granted by assigning "
     "an SSO permission set, zero cluster changes per person. Using one identity source for "
     "both kubectl and Argo CD means one place to grant and revoke.\n\n"
     "COST: Entra is the corporate directory of record and Identity Center sits downstream of "
     "it, so this is one hop further from the source of truth. In exchange it is achievable "
     "without waiting on anyone. If Azure access arrives later, moving Dex from a SAML "
     "connector to an OIDC one is a config change, not a redesign.\n\n" + DOC),

    ("INFRA-1642",
     "DECISION 2026-08-21 -- split, re-scoped, and the circularity resolved.\n\n"
     "The 'alert on stale sources' half is gone from this ticket: it turned out to be already "
     "written (INFRA-1503) and permanently unable to fire, and the real work became INFRA-1657 "
     "(scrape flux-system) and INFRA-1659 (deliver alerts at all). Summary updated to match.\n\n"
     "On the token: the circular problem was real -- ESO is reconciled BY Flux, so sourcing "
     "Flux's own Git credential from an ExternalSecret cannot work at bootstrap. The way out is "
     "not to solve the circularity but to remove the need for it. A PAT needs rotating because "
     "it expires and because it belongs to a person; an SSH DEPLOY KEY does neither.\n\n"
     "Convert the flux-system and infra GitRepository sources from https:// + PAT to ssh:// + "
     "deploy key. The credential then legitimately stays a BOOTSTRAP secret, written once by "
     "the cluster stand-up and never rotated -- which is not a workaround, it is the correct "
     "home for bootstrap material.\n\n"
     "COST: per-repository key again, and an ssh:// URL change on all three cluster branches. "
     "ssh:// and https:// are not interchangeable to Flux either. Make the change ON THE BRANCH "
     "and read git diff origin/<base> in full before pushing.\n\n" + DOC),

    ("INFRA-1654",
     "DECISION 2026-08-21 -- stop waiting for a reply, raise the PR.\n\n"
     "This was gated on a message to Idris that has not been sent. The port has been wrong for "
     "eleven weeks on dev and QA -- ghostunnel-rw-postgres listens on 4567, so rw-postgres has "
     "never been reachable, and the readiness probe passes because it checks the STATUS port, "
     "which is up (scripts/check-service-ports-listening.sh, 2026-08-20).\n\n"
     "It is a one-line manifest change. Writing the PR and asking him to approve it is one "
     "round trip; asking permission to write it and then writing it is two. He still gets the "
     "message -- COMMS-TO-IDRIS-2026-08-20.md also covers the Postgres password change in his "
     "namespace and the meta-pod recreation that needs his nod -- it just stops being a "
     "prerequisite for a one-line fix.\n\n" + DOC),

    ("INFRA-1655",
     "DECISION 2026-08-21 -- the on-prem half is answered and mitigated; the EKS half is cloud "
     "platform's and this ticket carries their name, not ours.\n\n"
     "ON-PREM IS SAFE FROM THIS: require-image-digest is Enforce on all three Talos clusters, "
     "so a mutated tag cannot be pulled by digest. That mitigation is real and in place.\n\n"
     "EKS IS NOT: usxpress-prod alone has 2763 tag references, 733 of them into the shared "
     "registry at 064859874041, and no image admission control at all. 515 of 517 repositories "
     "grant org-wide push and there is no registry-level policy.\n\n"
     "We should not hold this open pretending we will fix the cloud half. It needs a named "
     "owner on the cloud platform side. Risk of handing it over is that it rots -- mitigated by "
     "assigning it explicitly rather than leaving it unassigned, and by the finding being "
     "recorded in wip/onprem-app-cicd/ECR-REGISTRY-REVIEW-2026-08-20.md.\n\n" + DOC),

    ("INFRA-1638",
     "DECISION 2026-08-21 -- proceed. Dev first, prod in a scheduled window.\n\n"
     "Not blocked, just not started, and it is the ticket that unlocks the most: 'we cannot see "
     "prod' has been the qualifier on nearly every claim made in the last three days. Three PRs "
     "landed on op-prod on 2026-08-21 and none has been observed.\n\n"
     "The op-qa implementation is proven and portable (wip/onprem-qa-access/aws-sso-webhook/). "
     "Per cluster: an AWS SSO permission set in that account (ours -- we are admin), the role "
     "ARN mapped in aws-auth, enable_aws_iam_authenticator set as an OCTOPUS PROJECT VARIABLE "
     "(git .tfvars are NOT read -- deploys inject TF_VAR_* as env.auto.tfvars), TfApply=true "
     "scoped to the environment, and a Talos machineconfig patch pointing the apiserver at the "
     "webhook.\n\n"
     "COST: the machineconfig patch changes the API server on PRODUCTION. That is a change "
     "window, not an afternoon. Dev has no such constraint and goes first.\n\n"
     "Traps already paid for on QA: the authenticator binds 127.0.0.1 only, so an httpGet probe "
     "without host: is sent to the node IP and CrashLoops every pod (~140 times over 8 hours on "
     "QA); use tcpSocket with an explicit host. And a release pins a variable SNAPSHOT -- "
     "adding an Octopus variable does not reach an existing release without Update Variables.\n\n"
     + DOC),

    ("INFRA-1635",
     "2026-08-21 -- staying open deliberately, and here is the reasoning so it is not "
     "re-litigated.\n\n"
     "The written AC is arguably met: the QA overlay exists, is pinned by digest, renders "
     "clean, and risingwave-etl is Synced/Healthy with no Kyverno digest violation. But "
     "PIPELINE_DIR still points at /pipeline/smoke rather than pipelines/Brand, so nothing real "
     "has been promoted. Closing on the letter of the AC while the thing the ticket exists for "
     "has not happened is exactly how INFRA-1640 and INFRA-1641 were wrongly closed.\n\n"
     "Blocked on INFRA-1644, which is a question about what the pipeline is FOR and is not ours "
     "to answer.\n\n" + DOC),

    ("INFRA-1644",
     "2026-08-21 -- needs Tim. Flagging rather than deciding, because this is not ours to "
     "decide: the repo's 400-sink.rw defines sinks that the live op-dev cluster does not run, "
     "and which of those is correct is a question about the pipeline's purpose.\n\n"
     "It gates INFRA-1635, so it is on the critical path for promoting anything real through "
     "the delivery pipeline we finished building on 2026-08-20.\n\n" + DOC),

    ("INFRA-1651",
     "2026-08-21 -- ours, not started, no blocker. Recording it so it is not mistaken for "
     "blocked.\n\n"
     "The ECR repository and its policy were created BY HAND during INFRA-1633 and sit outside "
     "Terraform. Related and larger: the registry-wide finding in INFRA-1655 -- 515 of 517 "
     "repositories in 064859874041 grant org-wide push with no registry policy. Bootstrapping "
     "a Terraform path into that account is the prerequisite for fixing either properly.\n\n"
     + DOC),

    ("INFRA-1657",
     "2026-08-21 -- do this one FIRST of the three alerting tickets. It is small, independent, "
     "and without it every Flux rule stays permanently inactive no matter how good delivery "
     "becomes.\n\n"
     "Manifest drafted: wip/observability/platform/prometheus/flux-podmonitor.yaml.\n\n"
     "THE SELECTOR LABEL IS LOAD-BEARING. kube-prometheus-stack sets "
     "podMonitorSelectorNilUsesHelmValues: true, so the Prometheus CR selects PodMonitors by "
     "matchLabels {release: prometheus-stack} -- the same convention platform-alerts.yaml "
     "documents for ruleSelector. Without that label the object applies cleanly, the "
     "Kustomization goes Ready=True, and it is never selected: this ticket's own failure mode, "
     "reproduced inside its own fix.\n\n"
     "ACCEPTANCE is not 'series count > 0'. Make a Kustomization fail deliberately on op-dev "
     "and watch FluxKustomizationFailed reach 'firing'. A rule that has never been SEEN to go "
     "red is not a rule anyone should trust.\n\n" + DOC),

    ("INFRA-1659",
     "2026-08-21 -- sequenced LAST of the three, deliberately, and do not let it jump the queue "
     "because it is the most visible.\n\n"
     "Enabling delivery before INFRA-1658's triage would deliver two months of backlog on day "
     "one: 54 firing alerts, oldest 2026-06-24, including at least one likely Talos false "
     "positive (KubeControllerManagerDown -- control-plane components are static pods the "
     "default scrape config does not reach) and application outages that are not ours "
     "(attrition/, io-curt/, NotReady since 2026-06-24). The channel would be dismissed inside "
     "a week, and the next real alert with it.\n\n" + DOC),
]

# ---------------------------------------------------------------- re-scope ---
RESCOPE = [("INFRA-1642", "Fix the Flux Git credential at source: move it off a PAT to a deploy key")]

# ---------------------------------------------------------------- new ticket -
CREATE = [
    {"summary": "Migrate on-prem Git credentials from per-repo deploy keys to an org GitHub App",
     "desc":
        "Filed 2026-08-21 so that DEFERRING the GitHub App is a recorded decision with a ticket, "
        "rather than an intention that silently blocks other work. It blocked INFRA-1636 and "
        "INFRA-1650 for two days without anyone choosing that.\n\n"
        "Argo CD on op-usxpress-qa, and shortly op-usxpress-prod, authenticates to variant-inc "
        "repositories with a per-repository DEPLOY KEY. Flux is moving the same way under "
        "INFRA-1642. That satisfies every stated requirement -- repo-owned, no expiry, survives "
        "offboarding, not tied to a person -- and it does NOT scale: one key per repository.\n\n"
        "An org-owned GitHub App issues short-lived installation tokens that Argo CD renews "
        "itself, and one installation covers every repository. At two or three applications "
        "deploy keys are fine. At fifteen they are an administrative mess and nobody will know "
        "which keys are live.\n\n"
        "BLOCKED ON: variant-inc owner rights. dare-x is a member, not an owner -- the New "
        "GitHub App page returns 404 (verified 2026-08-20 via gh api orgs/variant-inc/"
        "memberships). Owners as of 2026-08-20: usx-devops, buddy-james, higdonmatthew, "
        "stevebduckjr, svivesusx.\n\n"
        "The request is already written: wip/onprem-app-cicd/REQUEST-GITHUB-APP-OWNER.md. It "
        "needs App ID, Installation ID and the private key, and the key must not come through "
        "chat.\n\n"
        "TRIGGER: revisit when the on-prem delivery path carries more than about five "
        "applications, or sooner if an owner becomes available. Until then this is a scaling "
        "improvement, not a prerequisite -- which is the whole point of filing it.\n\n" + DOC,
     "labels": ["onprem", "argocd", "deferred"]},
]

# ------------------------------------------------------- verified closures ---
def gh_json(path):
    """Read the GitHub API via the gh CLI. Returns None if it cannot be read."""
    if not shutil.which("gh"):
        return None, "gh CLI not on PATH"
    try:
        p = subprocess.run(["gh", "api", path], capture_output=True, text=True, timeout=30)
    except Exception as e:                                        # noqa: BLE001
        return None, str(e)[:200]
    if p.returncode != 0:
        return None, (p.stderr or p.stdout).strip()[:200]
    try:
        return json.loads(p.stdout), None
    except Exception as e:                                        # noqa: BLE001
        return None, f"unparseable response: {e}"


def verify_1656():
    """INFRA-1656 asks for review-required branch protection on op-prod.

    PROVE it before closing. A ticket closed on the strength of its own
    description is how INFRA-1640 and INFRA-1641 went wrong.
    """
    data, err = gh_json(f"repos/{REPO}/branches/op-prod/protection")
    if data is None:
        return False, f"could not read branch protection ({err})"
    rev = data.get("required_pull_request_reviews")
    if not rev:
        return False, "branch protection exists but requires NO pull request review"
    n = rev.get("required_approving_review_count", 0)
    if n < 1:
        return False, f"review block present but required_approving_review_count={n}"
    return True, (f"op-prod requires {n} approving review(s); "
                  f"dismiss_stale_reviews={rev.get('dismiss_stale_reviews')}")


VERIFIED_CLOSE = [
    ("INFRA-1656", verify_1656,
     "CLOSED 2026-08-21. Branch protection now requires an approving review on the op-prod "
     "branch of iaac-talos-flux-platform. Adopted option (a) from the ticket.\n\n"
     "op-dev and op-qa stay on auto-merge deliberately -- the cost of a review gate is one "
     "round trip per change, and it is only worth paying where a merge is a production deploy.\n\n"
     "NOT adopting option (d), a check requiring the change to be live on another cluster "
     "first. It is the more correct control and it is also a bespoke CI job nobody will "
     "maintain. Review-required gets most of the benefit for none of the upkeep. If unverified "
     "changes start reaching prod anyway, revisit.\n\n"
     "Verified by scripts/decide-and-close-2026-08-21.py before closing, by reading "
     "GET /repos/{repo}/branches/op-prod/protection and asserting "
     "required_pull_request_reviews.required_approving_review_count >= 1. The check result is "
     "quoted below.\n\n" + DOC),
]

# ---------------------------------------------------------------- assignment -
ASSIGN_SELF = ["INFRA-1636", "INFRA-1650", "INFRA-1639", "INFRA-1642", "INFRA-1651",
               "INFRA-1654", "INFRA-1656", "INFRA-1657", "INFRA-1658", "INFRA-1659"]
LEAVE_ALONE = {"INFRA-1637": "Idris, In Progress",
               "INFRA-1644": "needs Tim -- a question about what the pipeline is for",
               "INFRA-1655": "needs a named cloud-platform owner"}


def my_account_id():
    status, body = m.api("GET", "/rest/api/3/myself")
    if status == 200 and isinstance(body, dict):
        return body.get("accountId"), body.get("displayName")
    return None, None


def assign(issue, account_id, who):
    if not GO:
        print(f"  [plan] assign {issue} -> {who}")
        return
    status, body = m.api("PUT", f"/rest/api/3/issue/{issue}/assignee", {"accountId": account_id})
    print(f"  assign {issue} -> {who}: {'OK' if status in (200, 204) else f'{status} {body}'}")


def main():
    print(f"== decide-and-close-2026-08-21  [{'EXECUTING' if GO else 'DRY RUN (pass --go)'}]\n")
    m.preflight()

    print("-- decisions, recorded on each ticket --")
    for issue, body in COMMENT:
        print(issue); m.do_comment(issue, body)

    print("\n-- re-scope --")
    for issue, summary in RESCOPE:
        if not GO:
            print(f"  [plan] summary {issue} -> {summary}")
        else:
            st, bd = m.api("PUT", f"/rest/api/3/issue/{issue}", {"fields": {"summary": summary}})
            print(f"  summary {issue}: {'OK' if st in (200, 204) else f'{st} {bd}'}")

    print("\n-- new ticket (deferring the App is a decision, so it gets a ticket) --")
    for s in CREATE:
        m.do_create(s)

    print("\n-- closures, each verified before closing --")
    for issue, verifier, body in VERIFIED_CLOSE:
        ok, detail = verifier()
        print(f"{issue}: {'VERIFIED' if ok else 'NOT VERIFIED'} -- {detail}")
        if not ok:
            print(f"  SKIPPING close of {issue}. Apply the change, then re-run.")
            continue
        m.do_comment(issue, body + f"\n\nVerification output: {detail}")
        m.do_close(issue)

    print("\n-- ownership --")
    aid, name = my_account_id()
    if not aid:
        print("  !! could not resolve own accountId; skipping assignment")
    else:
        for issue in ASSIGN_SELF:
            assign(issue, aid, name)
    for issue, why in LEAVE_ALONE.items():
        print(f"  left alone {issue}: {why}")


if __name__ == "__main__":
    main()
