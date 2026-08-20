#!/usr/bin/env python3
"""
Close the UI Sprint 3 tickets whose acceptance criteria are actually met, comment
the evidence on each, and file the follow-ups the work uncovered.

Written 2026-08-20 after the on-prem app delivery path ran end to end on
op-usxpress-qa. Evidence for every closure is in
wip/onprem-app-cicd/FINDINGS-2026-08-20.md.

Deliberately conservative: a ticket is closed only where its stated AC is met.
INFRA-1635 is NOT closed -- the QA overlay works, but PIPELINE_DIR still points at
the smoke payload rather than pipelines/Brand.

DRY-RUN BY DEFAULT. Pass --go to execute.

Auth (WSL): export ATLASSIAN_TOKEN=...
"""
import base64, json, os, sys, urllib.error, urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GO = "--go" in sys.argv
BASE = "https://usxpress.atlassian.net"
EMAIL = os.environ.get("JIRA_EMAIL", "doke@usxpress.com")
PROJECT = "INFRA"
EPIC = "INFRA-1632"

# ---- close: (issue, comment) -------------------------------------------------
CLOSE = [
    ("INFRA-1647",
     "DONE on op-usxpress-qa 2026-08-20. Argo CD held no Git credential at all -- no secret "
     "on either cluster carried the argocd.argoproj.io/secret-type label, so every Application "
     "pointing at an internal variant-inc repo failed with 'ComparisonError: authentication "
     "required'. Delivered as a repository DEPLOY KEY (secret-type: repository, exact ssh:// "
     "URL) rather than the intended org GitHub App: dare-x is a member of variant-inc, not an "
     "owner, so creating an org App needs someone else. A fine-grained PAT was rejected -- it "
     "is owned by a user account even when the resource owner is the org, which fails the "
     "'no CI/CD tied to a person' requirement. The deploy key is repo-owned, does not expire "
     "and is unaffected by offboarding. Merged as iaac-talos-flux-platform#97. "
     "PROD IS NOT DONE -- tracked by the new prod credential ticket."),

    ("INFRA-1648",
     "DONE 2026-08-20. Proof is one row in pipeline_applied on QA's Postgres: "
     "smoke/001-connectivity.rw | 4b65ef49e1c4 | 2026-08-20 16:26:47+00 | argocd-qa. That row "
     "can only exist if every link held: GitHub Actions built the image and pushed it by "
     "digest, ECR served it cross-account, ecr-pull-secret authenticated the pull, Argo CD read "
     "an internal repo over the deploy key, the QA overlay rendered, the sync-hook Job ran "
     "inside the cluster, External Secrets supplied the credentials, Postgres accepted them and "
     "RisingWave executed the SQL. First application ever delivered to an on-prem cluster this "
     "way."),

    ("INFRA-1633",
     "AC met 2026-08-20: a GitHub Actions run assuming gha-risingwave-etl-ecr-push pushed "
     "risingwave/etl-pipeline by digest (sha256:d6162426...) and IMMUTABLE tags refused an "
     "overwrite. Two corrections found by doing it: (1) the push role also needs READ on its "
     "own repository -- buildx reads the manifest back after pushing, so the build failed after "
     "every layer had uploaded with a message that reads like a push permission problem; (2) a "
     "new ECR repository has NO repository policy, so it is unreadable from any other account "
     "-- the kubelet reports 403 Forbidden on the manifest HEAD, which reads like a broken pull "
     "secret. ECR authorises per repository; the pull secret only authenticates to the "
     "registry. A pull-only policy for the three cluster accounts was applied. "
     "CLOSING THIS DOES NOT MEAN IT IS IN TERRAFORM -- see the new IaC ticket."),

    ("INFRA-1634",
     "Closing: the premise was wrong. variant-inc/risingwave-pipeline has existed since May "
     "2026 with the SQL versioned and a working ARC-runner pipeline for op-usxpress-dev. The "
     "re-scoped work -- extend it to QA and prod -- was delivered as risingwave-pipeline #9 "
     "(image build, deploy/ tree, smoke payload), #10 (disable the inherited Octopus build.yaml, "
     "which had been failing every push in that repo since the fork and red-flagging everyone's "
     "PRs) and #11 (digest promotion). Dev's runner and pipeline.yaml are untouched."),
]

# ---- comment only, stay open -------------------------------------------------
COMMENT_ONLY = [
    ("INFRA-1635",
     "Partially done, staying open. The QA overlay exists, is pinned by digest and renders "
     "clean -- risingwave-etl is Synced/Healthy and Kyverno raises no digest violation, so the "
     "stated AC is technically met. But PIPELINE_DIR still points at /pipeline/smoke, not "
     "pipelines/Brand, so nothing real has been promoted. Swapping it in depends on INFRA-1644 "
     "(repo and live dev cluster have diverged: 400-sink.rw defines sinks, dev runs none). "
     "Three defects were fixed in the QA overlay on 2026-08-20: a dev postgres service name, "
     "PG_USER asserted in a ConfigMap while its password lived in Secrets Manager (SM holds "
     "username 'risingwave', the overlay said 'postgres'), and PG_DB 'postgres' where the "
     "StatefulSet's POSTGRES_DB is 'risingwave'."),

    ("INFRA-1643",
     "Confirmed and now concrete. lazy/api's repository policy grants PutImage, "
     "InitiateLayerUpload and CompleteLayerUpload to EVERY principal in org o-yza5l1xhrc, so "
     "anything in the org can publish into it. The new risingwave/etl-pipeline policy "
     "deliberately does not copy that shape: three read actions "
     "(GetDownloadUrlForLayer, BatchGetImage, BatchCheckLayerAvailability) to three named "
     "cluster accounts, no write. Push needs no policy entry because the GitHub OIDC role lives "
     "in the registry's own account. The decision this ticket asks for is whether the existing "
     "repositories get narrowed to match."),

    ("INFRA-1642",
     "Related finding 2026-08-20: the Argo CD Git credential deliberately does NOT reuse the "
     "hand-patched Flux PAT. It is a repository deploy key with no expiry, so this ticket is no "
     "longer a blocker for app delivery. The QA Flux token itself is still hand-patched and the "
     "next iaac-talos deploy reverts it -- unchanged."),
]

# ---- new tickets the work uncovered ------------------------------------------
CREATE = [
    {"summary": "Argo CD Git credential and ApplicationSet on op-usxpress-prod",
     "desc": "op-usxpress-prod has the platform half (ecr-credentials, app-namespaces, "
             "app-risingwave) but no Git credential and no ApplicationSet, so no application "
             "can be delivered there. QA's answer was a repository deploy key; prod needs its "
             "own key or, preferably, the org GitHub App if one has been created by then. The "
             "prod ApplicationSet must ship with NO automated sync. Depends on INFRA-1636.",
     "labels": ["onprem", "argocd", "prod"]},

    {"summary": "Bootstrap a Terraform path into ECR account 064859874041, and adopt the "
                "hand-made repository and policy",
     "desc": "INFRA-1633 was never blocked on finding which repo owns 064859874041 -- nothing "
             "does. aws_ecr_repository appears exactly once in the whole variant-inc org, in an "
             "interview sandbox. iac-tf-common-endpoints has plan.yml and apply.yml but assumes "
             "arn:aws:iam::064859874041:role/github-iac-ecr-vpc-endpoint-role, which does NOT "
             "exist (NoSuchEntity) -- that repo is dormant. iac-tf-manual-runs commits "
             "terraform.tfstate to git and has no apply workflow, so it is not a home.\n\n"
             "The GitHub OIDC provider DOES exist in that account, so the bootstrap is: create "
             "one github-iac-ecr role by hand (the single irreducible manual step -- Terraform "
             "cannot create the credential it authenticates with), choose a repo home "
             "(revive iac-tf-common-endpoints, or generate one from iaac-template, which is the "
             "org's plan-on-PR / apply-on-merge pattern), then put ecr-app-repos.tf and "
             "imports.tf there and import the existing repository and policy.\n\n"
             "terraform plan must show ZERO changes for the imports -- replacing an ECR "
             "repository deletes every image in it, including the digest QA runs. Draft code is "
             "in wip/onprem-app-cicd/terraform/.",
     "labels": ["onprem", "terraform", "ecr"]},

    {"summary": "op-usxpress-qa Postgres never learned its rotated password; recreate the "
                "RisingWave meta pod, and check dev and prod for the same shape",
     "desc": "pg-postgresql in the risingwave namespace on op-usxpress-qa was initialised "
             "2026-08-11 19:20 UTC. op-usxpress-qa/risingwave/postgres was rotated 2026-08-12 "
             "13:35 UTC. POSTGRES_PASSWORD applies only at initdb, so the database kept the "
             "08-11 value while Secrets Manager, pg-credentials, risingwave-pg-credentials and "
             "the ETL Job all carried the 08-12 one -- identical hashes, all four disagreeing "
             "with the database.\n\n"
             "Invisible for 8 days because env from secretKeyRef resolves at POD creation, not "
             "container restart: risingwave-meta-default-0 was created before the rotation, so "
             "its 238 container restarts each replayed the old password and each succeeded. The "
             "first thing to use the credential fresh was INFRA-1648's smoke test.\n\n"
             "Fixed 2026-08-20 with ALTER USER risingwave WITH PASSWORD, run inside "
             "pg-postgresql-0 (initdb enables trust for LOCAL connections, so no prior password "
             "is needed -- also useful as a recovery route).\n\n"
             "OUTSTANDING: the fix inverted meta's exposure -- its pod env still holds the "
             "pre-rotation password, so a container restart now fails where a pod recreation "
             "succeeds. Recreate risingwave-meta-default-0 to close it.\n\n"
             "ALSO: any Postgres on dev or prod built before its secret was rotated has the same "
             "dormant fault. scripts/check-postgres-secret-usable.sh answers it in one run -- it "
             "compares initdb against LastChangedDate and then actually authenticates over TCP.\n\n"
             "Separately: 238 SIGSEGV (exit 139) restarts of RisingWave meta in its first 16 "
             "hours, unremarked at the time.",
     "labels": ["onprem", "risingwave", "secrets"]},

    {"summary": "Argo CD sync hooks delete their own evidence: set "
                "BeforeHookCreation,HookSucceeded and lower the retry limit",
     "desc": "hook-delete-policy: BeforeHookCreation plus Argo CD's five automatic retries means "
             "each retry destroys the previous attempt's pod and logs -- on 2026-08-20 it took "
             "three separate attempts to read a single failure, and on final failure Argo CD "
             "removed the Job entirely.\n\n"
             "HookSucceeded alone is not the answer either: it fixes the failure case and breaks "
             "the success case (it deletes the evidence OF success), and a retained failed Job "
             "then blocks the next sync with AlreadyExists.\n\n"
             "Correct setting is BeforeHookCreation,HookSucceeded plus a lower retry limit on "
             "the ApplicationSet template, so a failure stops at once and persists until someone "
             "deliberately re-syncs. Platform repo, op-qa branch, "
             "infrastructure/argocd-apps/applicationset-qa.yaml.",
     "labels": ["onprem", "argocd"]},
]


def get_token():
    t = os.environ.get("ATLASSIAN_TOKEN") or os.environ.get("CONFLUENCE_TOKEN")
    if t:
        return t.strip()
    f = REPO / "scripts" / "push-to-confluence.sh"
    if f.exists():
        for ln in f.read_text().splitlines():
            if ln.strip().startswith("CONFLUENCE_TOKEN="):
                return ln.split("=", 1)[1].strip().strip('"').strip("'")
    sys.exit("No token: set ATLASSIAN_TOKEN (or CONFLUENCE_TOKEN in push-to-confluence.sh)")


AUTH = "Basic " + base64.b64encode(f"{EMAIL}:{get_token()}".encode()).decode()


def api(method, path, body=None):
    url = BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": AUTH, "Accept": "application/json", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw[:400]}


def adf(text):
    return {"type": "doc", "version": 1, "content": [
        {"type": "paragraph", "content": [{"type": "text", "text": p}]}
        for p in text.split("\n\n")]}


def do_comment(issue, body):
    if not GO:
        print(f"  [plan] comment {issue}: {body[:70]}...")
        return
    s, r = api("POST", f"/rest/api/3/issue/{issue}/comment", {"body": adf(body)})
    print(f"  comment {issue}: {'OK' if s in (200,201) else f'FAIL {s} {r}'}")


def do_close(issue):
    if not GO:
        print(f"  [plan] transition {issue} -> Done")
        return
    s, tr = api("GET", f"/rest/api/3/issue/{issue}/transitions")
    target = None
    for t in tr.get("transitions", []):
        cat = (t.get("to", {}).get("statusCategory", {}) or {}).get("key")
        nm = t.get("name", "").lower()
        if cat == "done" or any(w in nm for w in ("done", "close", "resolve")):
            target = t
            break
    if not target:
        print(f"  !! {issue}: no closing transition "
              f"({[t.get('name') for t in tr.get('transitions', [])]})")
        return
    for fields in ({"resolution": {"name": "Done"}}, None):
        body = {"transition": {"id": target["id"]}}
        if fields:
            body["fields"] = fields
        s, r = api("POST", f"/rest/api/3/issue/{issue}/transitions", body)
        if s in (200, 204):
            print(f"  closed {issue} via '{target['name']}'")
            return
    print(f"  !! {issue} transition failed: {s} {r}")


def do_create(spec):
    if not GO:
        print(f"  [plan] create: {spec['summary'][:78]}")
        return
    fields = {
        "project": {"key": PROJECT},
        "summary": spec["summary"],
        "description": adf(spec["desc"]),
        "issuetype": {"name": "Task"},
        "labels": spec.get("labels", []),
    }
    s, r = api("POST", "/rest/api/3/issue", {"fields": fields})
    if s in (200, 201):
        key = r.get("key")
        print(f"  created {key}: {spec['summary'][:60]}")
        s2, _ = api("PUT", f"/rest/api/3/issue/{key}",
                    {"fields": {"parent": {"key": EPIC}}})
        print(f"    parent -> {EPIC}: {'OK' if s2 in (200, 204) else 'not set (check epic field)'}")
    else:
        print(f"  !! create failed {s}: {r}")


def preflight():
    """Prove the token works before attempting any mutation.

    Jira answers an unauthenticated request with 404 on an issue -- it will not
    confirm the issue exists -- and 400 on create. Both read like permission
    problems rather than auth ones. On 2026-08-20 a --go run made eleven calls
    and failed all eleven that way, because ATLASSIAN_TOKEN had been set to the
    literal placeholder text from an instruction."""
    s, r = api("GET", "/rest/api/3/myself")
    if s != 200:
        tok = os.environ.get("ATLASSIAN_TOKEN", "")
        print(f"!! cannot authenticate to {BASE} as {EMAIL}  (HTTP {s})")
        if tok in ("...", "<token>", "") or len(tok) < 20:
            print(f"   ATLASSIAN_TOKEN looks wrong: {len(tok)} characters.")
            print("   Set it without typing it into history:")
            print("     read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo")
        else:
            print("   The token is a plausible length, so it may be expired or revoked.")
            print("   Mint a new one: https://id.atlassian.com/manage-profile/security/api-tokens")
        sys.exit(1)
    print(f"authenticated as {r.get('displayName')} <{r.get('emailAddress', EMAIL)}>\n")


def main():
    mode = "EXECUTING" if GO else "DRY RUN (pass --go to execute)"
    print(f"== close-sprint3-tickets  [{mode}]\n")
    preflight()

    print("-- closing (AC met, evidence commented) --")
    for issue, comment in CLOSE:
        print(f"{issue}")
        do_comment(issue, comment)
        do_close(issue)

    print("\n-- commenting, staying open --")
    for issue, comment in COMMENT_ONLY:
        print(f"{issue}")
        do_comment(issue, comment)

    print("\n-- creating follow-ups --")
    for spec in CREATE:
        do_create(spec)

    print("\nNot touched, and why:")
    print("  INFRA-1636 prod ApplicationSet     - not started")
    print("  INFRA-1637 rotate Confluent creds  - not started, still the most urgent")
    print("  INFRA-1638 SSO to dev and prod     - not started")
    print("  INFRA-1639 Argo CD SSO for app teams - blocked on an Entra app registration")
    print("  INFRA-1640 Kyverno Audit -> Enforce  - waits on the first real app deploy")
    print("  INFRA-1641 harden ecr-credentials-sync - not started")
    print("  INFRA-1644 repo/cluster drift      - Tim's call, gates any real promotion")
    print("  INFRA-1645/1646 QA L4 routes, pre-merge grep - not started")


if __name__ == "__main__":
    main()
