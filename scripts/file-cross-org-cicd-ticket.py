#!/usr/bin/env python3
"""File the cross-org CI/CD ticket and put it on UI Sprint 6 (6290).

From the 2026-10-07 call: the app team consumes PUBLISHED reusable workflows and
never passes repo keys around. Our app-template breaks both. The fix joins the two
GitHub orgs at ECR via OIDC instead of at GitHub via a token.

DRY-RUN BY DEFAULT. Pass --go to write.

Auth (never on the command line, never pasted into chat):
    read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo
    export ATLASSIAN_EMAIL=<your atlassian login email>
"""
import json, os, sys, urllib.request, urllib.error, base64

BASE    = "https://usxpress.atlassian.net"
PROJECT = "INFRA"
SPRINT  = 6290                 # UI Sprint 6, 2026-10-05 -> 2026-10-16
SPRINT_FIELD = "customfield_10010"   # Sprint. A WRONG name returns 200 with it absent.
GO = "--go" in sys.argv

EMAIL = os.environ.get("ATLASSIAN_EMAIL", "")
TOKEN = os.environ.get("ATLASSIAN_TOKEN", "")
if not TOKEN or not EMAIL:
    sys.exit("set ATLASSIAN_EMAIL and ATLASSIAN_TOKEN in the environment (not argv)")
AUTH = base64.b64encode(f"{EMAIL}:{TOKEN}".encode()).decode()


def call(method, path, body=None):
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("Authorization", "Basic " + AUTH)
    req.add_header("Accept", "application/json")
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, data, timeout=30) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:600]


def adf(text):
    """Plain text -> Atlassian Document Format. Blank line separates paragraphs;
    a single newline becomes a hardBreak so lists do not collapse onto one line."""
    out = []
    for para in text.split("\n\n"):
        nodes, lines = [], para.split("\n")
        for i, ln in enumerate(lines):
            if i:
                nodes.append({"type": "hardBreak"})
            if ln:
                nodes.append({"type": "text", "text": ln})
        out.append({"type": "paragraph", "content": nodes or [{"type": "text", "text": " "}]})
    return {"type": "doc", "version": 1, "content": out}


SUMMARY = "App CI/CD across two GitHub orgs: publish a reusable workflow, join at ECR via OIDC"

DESC = """From the RisingWave pipeline call on 2026-10-07 (Steve Duck, Timothy Preble, Idris Fagbemi, Pujit Koirala, Dare Oke).

THE CALL WAS DECIDING THE WRONG THING.
The question asked was which GitHub org the pipeline repo should live in. Moving it costs, in Idris's words, a redirect of the pipeline and everything pointing at the RisingWave server -- "a little bit of a restart". It buys nothing. The platform needs exactly one thing from an app repo: an image in ECR. That is an AWS boundary and it does not care which GitHub org the source sits in.

THE REAL CONSTRAINT, STATED ON THE CALL.
Tim described a USX standard, not a preference: "We have not been custom curating our deployment from scratch. We have used actions that have come out of the variant space... you just create it and then you publish it and then it gets used." And on credentials: "We've never done those repo keys and passing things around."

Our app-template/.github/workflows/build-and-push.yml breaks both. It is a 90-line workflow the app team copies into their repo and thereafter owns, and its promotion job needs a token stored in their org to write a PR into ours. Right content, wrong packaging.

It is also the wall we are stuck behind from the other side. Doke on the call: "the problem with the key is because neither of us -- you, myself, Idris -- we don't have permission to your repo." Two teams unable to credential each other is not solved by picking whose org wins. It is solved by removing the credential.

WHAT THIS TICKET DELIVERS.
1. A reusable workflow published in variant-inc (usx-cicd-workflows), called with `uses:` -- the shape Tim asked for.
2. The app repo's entire pipeline becomes 44 lines with two values and NO SECRETS. Credential is a GitHub OIDC token, issued per run, expiring in minutes.
3. The QA promotion PR is opened on the PLATFORM side, because the overlays live there. The app repo needs no write access to ours; Argo CD never reads theirs. The orgs join at ECR.
4. Terraform trust policy where adding an app is one map entry and revoking it is deleting a line.

Drafted and parsing: wip/onprem-app-cicd/cross-org/ -- app-build-push.yml, deploy.yml, promote-from-ecr.yml, gha-oidc-trust.tf, validate-cross-org-actions.sh, FINDINGS-2026-10-07-two-orgs-one-pipeline.md

FOUR THINGS UNVERIFIED. Do not promise this to the app team until step 1 is settled.
1. Can a USX-org repo `uses:` a PRIVATE variant-inc reusable workflow? Only if both orgs sit in the same GitHub enterprise AND the source repo's Actions access_level is 'enterprise'. If not, no permission level fixes it -- the fallback is to publish usx-cicd-workflows public, since it holds workflow logic and no secrets. EVERYTHING depends on this.
2. Does the USX org run an Actions allowlist (allowed_actions=selected)? If so our workflow must be added to patterns_allowed.
3. Exact org and repo spelling. The transcript garbles the USX org. The OIDC sub is a literal string match, so a wrong guess fails as a generic authorization error that reads like a permissions bug.
4. Who adds the 44 lines to Tim's repo. We cannot -- we have no access. It should be a PR he reviews.

ACCEPTANCE. Each step proves itself before the next.
A. validate-cross-org-actions.sh run against the real org names; step 2 returns access_level=enterprise, or the repo is public.
B. usx-cicd-workflows created in variant-inc holding app-build-push.yml, tagged v1.
C. Trust policy applied; `aws sts get-caller-identity` inside a run shows the assumed role.
D. SAME-ORG proof first: a variant-inc repo calls the workflow and pushes a digest to ECR. This isolates the workflow logic from the cross-org hop.
E. CROSS-ORG proof: a repo in the USX org calls it and pushes. Until this run is green the cross-org hop is UNPROVEN -- a passing API check is not a substitute, because no API answers whether `uses:` resolves at run time.
F. promote-from-ecr.yml opens a QA PR carrying the digest from E, and Argo CD applies it on op-usxpress-qa.

TRAPS, RECORDED SO THEY ARE NOT REDISCOVERED.
- The OIDC sub is org-qualified. A repo transferred between orgs stops authenticating at once, with nothing changed on its side and an error naming permissions rather than the claim. If the org question is ever revisited, the trust policy moves in the same change.
- Pinning environment:<name> in the sub requires the calling job to declare `environment:`. Our policy pins repo + ref for this reason.
- A scheduled promotion workflow that finds nothing still reports success. Green means the poll ran, not that an image was promoted.

SEPARATE AND MORE URGENT: Tim is not blocked on any of this. He is blocked on a local Docker container-user / file-ownership mismatch -- "the folder is being owned by the user, the user is not included inside of the Docker container... I'm way behind." That is an hour from someone who has seen it before, and it is the only thing actually stopping work today."""


def main():
    code, me = call("GET", "/rest/api/3/myself")
    if code != 200:
        sys.exit(f"preflight failed: HTTP {code} {me}\n"
                 "A bad token reads as 404/permissions, never as 'bad token'.")
    print(f"authenticated as {me.get('displayName')} <{me.get('emailAddress')}>")

    payload = {"fields": {
        "project":   {"key": PROJECT},
        "summary":   SUMMARY,
        "issuetype": {"name": "Task"},
        "description": adf(DESC),
    }}

    if not GO:
        print("\n--- DRY RUN, nothing written. Pass --go ---")
        print("summary:", SUMMARY)
        print("sprint :", SPRINT, "via", SPRINT_FIELD)
        print(f"description: {len(DESC)} chars, {DESC.count(chr(10)+chr(10))+1} paragraphs")
        return

    code, res = call("POST", "/rest/api/3/issue", payload)
    if code not in (200, 201):
        sys.exit(f"create failed: HTTP {code} {res}")
    key = res["key"]
    print(f"created {key}")

    code, res = call("POST", f"/rest/agile/1.0/sprint/{SPRINT}/issue", {"issues": [key]})
    print(f"add to sprint {SPRINT}: HTTP {code} {res if code >= 300 else ''}")

    # Verify AT THE DESTINATION. Asking the issue for its sprint field is
    # indistinguishable from a typo: Jira drops field names it does not know and
    # returns 200 with the field simply absent.
    code, res = call("GET", f"/rest/agile/1.0/sprint/{SPRINT}/issue"
                            f"?fields=summary,status&maxResults=100")
    if code != 200:
        sys.exit(f"VERIFY FAILED: could not read sprint {SPRINT}: HTTP {code}")
    keys = [i["key"] for i in res.get("issues", [])]
    if key in keys:
        print(f"VERIFIED: {key} is on sprint {SPRINT} ({len(keys)} issues on the sprint)")
    else:
        sys.exit(f"VERIFY FAILED: {key} is NOT on sprint {SPRINT}. On it: {keys}")
    print(f"\n{BASE}/browse/{key}")


if __name__ == "__main__":
    main()
