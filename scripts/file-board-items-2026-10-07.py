#!/usr/bin/env python3
"""File the five items coming out of 2026-10-07 onto UI Sprint 6 (6290).

DRY-RUN BY DEFAULT. Pass --go.

Auth (never on the command line, never pasted into chat):
    export ATLASSIAN_EMAIL=<your atlassian login email>
    read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo
"""
import json, os, sys, base64, urllib.request, urllib.error

BASE, PROJECT, SPRINT = "https://usxpress.atlassian.net", "INFRA", 6290
GO = "--go" in sys.argv
EMAIL, TOKEN = os.environ.get("ATLASSIAN_EMAIL",""), os.environ.get("ATLASSIAN_TOKEN","")
if not (EMAIL and TOKEN):
    sys.exit("set ATLASSIAN_EMAIL and ATLASSIAN_TOKEN in the environment (not argv)")
AUTH = base64.b64encode(f"{EMAIL}:{TOKEN}".encode()).decode()


def call(method, path, body=None):
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("Authorization", "Basic " + AUTH)
    req.add_header("Accept", "application/json")
    data = None
    if body is not None:
        data = json.dumps(body).encode(); req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, data, timeout=30) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:500]


def adf(text):
    out = []
    for para in text.split("\n\n"):
        nodes, lines = [], para.split("\n")
        for i, ln in enumerate(lines):
            if i: nodes.append({"type": "hardBreak"})
            if ln: nodes.append({"type": "text", "text": ln})
        out.append({"type": "paragraph", "content": nodes or [{"type":"text","text":" "}]})
    return {"type": "doc", "version": 1, "content": out}


TICKETS = [
 ("RisingWave SQL exists twice and the two copies have diverged",
  """variant-inc/risingwave-pipeline carries 4 SQL files under pipelines/. usxpressinc/risingwave-poc carries 3. Ours has pipelines/Brand/300-transform.sql and the source repo does not.

This is the mirror taken when the platform pipeline was built. It has since drifted, so WHAT RUNS ON QA INCLUDES A TRANSFORM THAT IS NOT IN THE SOURCE OF TRUTH, and nobody owns the difference.

This is a correctness problem independent of CI/CD, and it must be decided BEFORE the cutover in usxpressinc/risingwave-poc#5, not after. Once that PR merges there is one copy and this cannot recur.

DONE WHEN: a named owner has confirmed which version is correct, the loser is deleted, and QA is confirmed running the agreed set."""),

 ("Import the four hand-made GitHub Actions IAM roles into Terraform",
  """Four OIDC push roles exist in AWS 064859874041 with NO tags and no Terraform behind them:

  gha-risingwave-etl-ecr-push      (pre-existing, created 2026-08-18)
  gha-sql-applier-ecr-push         (created 2026-10-07)
  gha-risingwave-poc-ecr-push      (created 2026-10-07)

The first one's description says "main branch only" while its trust policy actually pins master -- the description was already wrong about its own configuration.

Three of these were created by hand deliberately, to unblock the cross-org CI/CD proof. That is drift we chose to add and it should not stay.

wip/onprem-app-cicd/cross-org/terraform/gha-oidc-trust.tf is written and ready. It must IMPORT these roles, never declare them fresh: a second definition of a live role is how a destroy removes the real one (see the Hummock bucket incident).

DONE WHEN: terraform plan is clean with all roles imported, every role is tagged, and the descriptions match the trust policies."""),

 ("iaac-risingwave-cicd has 2 critical vulnerabilities and is now load-bearing",
  """As of 2026-10-07 this repo publishes the reusable workflows every on-prem app build calls, plus the SQL applier base image. It went from a docs repo to a delivery dependency in one afternoon.

GitHub reports 2 critical Dependabot alerts on its default branch (it was 1 earlier the same day).

Separately, its open Renovate branch renovate/major-github-actions-dependencies DELETES .github/workflows/publish-applier.yml -- it branched before that file existed. REBASE IT, DO NOT MERGE IT. Merging removes the applier build.

DONE WHEN: both alerts are resolved or explicitly accepted with a reason, and the Renovate branch is rebased."""),

 ("actions-collection pins trivy-action@master, a floating third-party ref",
  """variant-inc/actions-collection/build-push-image/build-push-core/action.yml uses:

    uses: aquasecurity/trivy-action@master

That is an unpinned reference to a third-party action, in the shared action that every USX application build consumes. Whatever lands on that branch runs in every pipeline, with no review and no version to roll back to.

Found 2026-10-07 while reading the action to align our own workflows with the house convention. Our workflows deliberately pin 0.35.0 instead.

Also worth taking from that file, which we DID copy: TRIVY_DB_REPOSITORY pointed at public.ecr.aws/aquasecurity/trivy-db:2, because Trivy's default database is on ghcr.io and gets rate-limited.

DONE WHEN: the reference is pinned to a tag or SHA and Renovate tracks it."""),

 ("Deploy the SQL pipeline image with Helm via Argo CD",
  """The build half is done: usxpressinc/risingwave-poc can build its SQL into an image and push it to ECR risingwave/poc-pipeline with no secrets (PR #5). NOTHING CONSUMES THAT IMAGE. The chain stops at the registry.

The usxpress-app Helm chart (wip/onprem-app-chart/) renders and lints clean and HAS NEVER BEEN APPLIED TO A CLUSTER. It replaces the Kustomize base/overlay pairs, which only cover two fixed shapes while seven object types have no template at all.

Scope:
  1. Land the chart in a repo Argo CD can read
  2. A values file for the RW SQL pipeline, image pinned by DIGEST
  3. An Argo Application on op-usxpress-qa, synced and green with the Job actually applying SQL
  4. Promotion: QA picks up a new digest automatically; prod is a separate human-merged PR against the SAME digest, nothing rebuilt between environments
  5. Only then retire the duplicated pipelines/ in risingwave-pipeline

PROMOTION ORDER APPLIES: prove on QA before prod.

DONE WHEN: a push to usxpressinc/risingwave-poc reaches op-usxpress-qa without a human touching anything but the merge button, and the applied SQL is verified in the database rather than inferred from a green sync."""),
]


def main():
    code, me = call("GET", "/rest/api/3/myself")
    if code != 200:
        sys.exit(f"preflight failed: HTTP {code} {me}\nA bad token reads as 404/permissions, never as 'bad token'.")
    print(f"authenticated as {me.get('displayName')} <{me.get('emailAddress')}>\n")

    if not GO:
        for i, (s, d) in enumerate(TICKETS, 1):
            print(f"{i}. {s}  ({len(d)} chars)")
        print(f"\n--- DRY RUN, nothing written. {len(TICKETS)} tickets -> sprint {SPRINT}. Pass --go ---")
        return

    created = []
    for summary, desc in TICKETS:
        code, res = call("POST", "/rest/api/3/issue", {"fields": {
            "project": {"key": PROJECT}, "summary": summary,
            "issuetype": {"name": "Task"}, "description": adf(desc)}})
        if code not in (200, 201):
            print(f"CREATE FAILED: {summary}\n  HTTP {code} {res}"); continue
        key = res["key"]; created.append(key)
        print(f"created {key}  {summary}")

    if not created:
        sys.exit("nothing created")

    code, res = call("POST", f"/rest/agile/1.0/sprint/{SPRINT}/issue", {"issues": created})
    print(f"\nadd {len(created)} to sprint {SPRINT}: HTTP {code} {res if code >= 300 else ''}")

    # Verify AT THE DESTINATION. Reading the sprint field off the issue is
    # indistinguishable from a typo: Jira drops field names it does not know and
    # returns 200 with the field simply absent.
    code, res = call("GET", f"/rest/agile/1.0/sprint/{SPRINT}/issue?fields=summary&maxResults=200")
    if code != 200:
        sys.exit(f"VERIFY FAILED: cannot read sprint {SPRINT}: HTTP {code}")
    on = {i["key"] for i in res.get("issues", [])}
    missing = [k for k in created if k not in on]
    if missing:
        sys.exit(f"VERIFY FAILED: not on sprint {SPRINT}: {missing}")
    print(f"VERIFIED: all {len(created)} on sprint {SPRINT} ({len(on)} issues total)")
    for k in created:
        print(f"  {BASE}/browse/{k}")


if __name__ == "__main__":
    main()
