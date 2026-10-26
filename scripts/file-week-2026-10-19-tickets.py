#!/usr/bin/env python3
"""File last week's untracked work onto Sprint 7, and give the pricing tickets an owner.

    python3 scripts/file-week-2026-10-19-tickets.py           # dry run, writes nothing
    python3 scripts/file-week-2026-10-19-tickets.py --go      # actually writes

Idempotent: every create is preceded by a summary search, so a re-run after a
partial failure assigns and transitions what exists rather than filing it twice.

Three things this board has taught us, all of them encoded here:
  * an API-created issue lands in the BACKLOG -- it must be added to the sprint
    explicitly, and the read-back at the end is what proves it arrived;
  * a bad token reads as 404 "does not exist or you do not have permission",
    so the preflight on /rest/api/3/myself runs before any write;
  * /rest/api/3/search is GONE (HTTP 410). This uses /rest/api/3/search/jql.
"""
import base64, json, os, sys, urllib.parse, urllib.request, urllib.error

SITE = "https://usxpress.atlassian.net"
EMAIL = os.environ.get("JIRA_EMAIL", "doke@usxpress.com")
PROJECT, SPRINT = "INFRA", 6296
GO = "--go" in sys.argv
CREDS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "push-to-confluence.sh")

PRICING = ["INFRA-1719", "INFRA-1720", "INFRA-1721", "INFRA-1722", "INFRA-1724"]

# summary, done?, paragraphs
NEW = [
 ("Office network could not reach the on-prem clusters: our own CiliumNetworkPolicy",
  True,
  ["Reported 2026-10-20 via Steve Duck for Jeremy Kays: staff in the office could not "
   "reach the on-prem URLs, while anyone at home on VPN could.",
   "Root cause was ours, not the network team's. allow-corp-vpn-to-ingressgateway "
   "admitted only the VPN pool, so office subnets were refused at the gateway. The "
   "policy was 140 days old and had been in place since INFRA-1496.",
   "The symptom misleads: a CiliumNetworkPolicy selects PODS, not nodes, so ICMP to the "
   "node still answered while TCP to the gateway was dropped. That reads as a routing "
   "or firewall fault and sent the first diagnosis to the wrong team.",
   "The corporate subnet list came from AD Sites and Services, which is authoritative "
   "and readable by any domain user, rather than from waiting on the network team.",
   "Fixed on all three clusters -- PR #178 dev, #179 QA, #180 prod -- taking the "
   "allow-list from 4 CIDRs to 22. Confirmed by Jenni Ray, who reported it, from "
   "10.10.72.227, and independently by Tim Preble from a second excluded subnet."]),

 ("RisingWave deploy path: Confluence runbook and the Lucid flow chart",
  True,
  ["Tim Preble asked for a flow chart of how a change reaches dev and QA. Delivered as "
   "two things that agree with each other: a written runbook and a diagram.",
   "The runbook is live at /wiki/spaces/UI/pages/4832657409, under CloudOps "
   "Administration. It opens with a context page carrying every URL a developer needs, "
   "then runs one continuous path -- laptop, dev, QA, production -- with a section on "
   "where each variable lives locally versus in the cluster.",
   "Idris drew the Lucid chart. Reviewed and corrected: QA and prod were shown flowing "
   "automatically, which is wrong -- a person runs both.",
   "Source markdown is in the repo so the page can be regenerated; "
   "scripts/push-rw-deploy-doc-confluence.sh publishes and reads the page back."]),

 ("usxpressinc/risingwave proven end to end, from push to objects in the catalog",
  True,
  ["Tim created the repo on 2026-10-21. By that evening a pipeline written in it was "
   "running on op-dev through every link of the chain: push 23:24, image in ECR "
   "23:24:53, promotion committed the digest 23:36:22, apply Job completed in 13s.",
   "Two faults had to be fixed. The OIDC trust needed the IMMUTABLE subject form "
   "(repo:usxpressinc@101195652/risingwave@1428674918:ref:refs/heads/master) -- a "
   "policy copied from an older repo can never match, and the error names IAM "
   "throughout, which sends you to permissions instead of to the claim.",
   "The Mongo sinks built a host:port URL against an Atlas mongodb+srv endpoint, which "
   "has no port. The working CONNECTION_STRING line was commented out directly above it.",
   "Proof is objects, not a green check: brand_sink_mongo and employees_sink_mongo "
   "exist in rw_catalog.rw_sinks."]),

 ("Service CIDR 10.96.0.0/12 overlaps four registered corporate subnets",
  False,
  ["Found while fixing the office allow-list. The Kubernetes service CIDR on all three "
   "on-prem clusters is 10.96.0.0/12, which spans 10.96 through 10.111.",
   "That range covers four /16s registered in AD Sites and Services as corporate "
   "networks: 10.100, 10.102, 10.107 and 10.110.",
   "Nothing is broken today, which is the danger -- a pod resolving one of those "
   "corporate addresses will route to a cluster service instead, and the failure will "
   "look like a DNS or application fault rather than an addressing collision.",
   "Live on dev, QA and prod. The service CIDR cannot be changed on a running cluster, "
   "so this needs a decision rather than a fix: accept and document, or re-address at "
   "the next rebuild."]),

 ("onprem-build.yml cannot restore Variant NuGet packages across the org boundary",
  False,
  ["usxpressinc/pricing-rfp-handler fails its build with 403 Forbidden restoring "
   "Variant.MessageHandler.Kafka, .Prometheus, .HealthChecks and Variant.HealthChecks."
   "Console from the variant-inc GitHub Packages feed.",
   "The failing workflow is onprem-build.yml, which is OURS. It builds the image by "
   "hand and passes secrets.GITHUB_TOKEN into the Dockerfile as a build arg. That token "
   "is minted for the repository that runs it and can never read another org's private "
   "packages; no permissions block changes that.",
   "The app's own octo-push.yaml does not have this problem, because actions-dotnet "
   "hands the build to variant-inc/actions-collection/build-push-image, which already "
   "authenticates to that feed. analytics-feed-handler and polygon-event-handler have "
   "identical Dockerfiles and build fine for that reason.",
   "So the question before fixing the credential is whether this workflow should exist "
   "at all. The agreement on 2026-10-20 was that on-prem reuses the ECR repository the "
   "app's existing pipeline already pushes to, rather than building a second image.",
   "Blocks INFRA-1715 and INFRA-1719."]),
]


def die(m):
    print(f"ABORT - {m}")
    sys.exit(1)


def token():
    for v in ("ATLASSIAN_TOKEN", "CONFLUENCE_TOKEN"):
        if os.environ.get(v):
            print(f"   token source: ${v}")
            return os.environ[v]
    if os.path.exists(CREDS):
        for line in open(CREDS):
            if line.startswith("CONFLUENCE_TOKEN="):
                print(f"   token source: {os.path.basename(CREDS)}")
                return line.split("=", 1)[1].strip().strip("\"'")
    die("no Atlassian token")


AUTH = base64.b64encode(f"{EMAIL}:{token()}".encode()).decode()


def api(method, path, body=None):
    r = urllib.request.Request(SITE + path, method=method,
                               data=json.dumps(body).encode() if body else None,
                               headers={"Authorization": "Basic " + AUTH,
                                        "Content-Type": "application/json",
                                        "Accept": "application/json"})
    try:
        with urllib.request.urlopen(r) as x:
            raw = x.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        die(f"HTTP {e.code} {method} {path}: {e.read().decode()[:300]}")


me = api("GET", "/rest/api/3/myself")
print(f"   authenticated as {me.get('displayName')} <{me.get('emailAddress')}>")
MY_ID = me["accountId"]


def find_user(name):
    for u in api("GET", "/rest/api/3/user/search?query=" + urllib.parse.quote(name)):
        if u.get("accountId"):
            return u["accountId"], u.get("displayName")
    die(f"no Jira user matching {name}")


IDRIS_ID, IDRIS_NAME = find_user("Idris")
print(f"   pricing tickets -> {IDRIS_NAME}")


def by_summary(s):
    q = f'project={PROJECT} AND summary~"{s[:40]}"'
    d = api("GET", "/rest/api/3/search/jql?maxResults=5&fields=summary&jql="
            + urllib.parse.quote(q))
    for i in d.get("issues", []):
        if i["fields"]["summary"] == s:
            return i["key"]
    return None


def adf(paras):
    return {"type": "doc", "version": 1,
            "content": [{"type": "paragraph",
                         "content": [{"type": "text", "text": p}]} for p in paras]}


def transition_to(key, want):
    for t in api("GET", f"/rest/api/3/issue/{key}/transitions")["transitions"]:
        if t["to"]["name"].lower() == want.lower():
            api("POST", f"/rest/api/3/issue/{key}/transitions", {"transition": {"id": t["id"]}})
            return t["to"]["name"]
    return None


print(f"\n== {'WRITING' if GO else 'DRY RUN - nothing is written'} ==\n")
created = []
for summary, done, paras in NEW:
    k = by_summary(summary)
    if k:
        print(f"   exists  {k}  {summary[:58]}")
    elif not GO:
        print(f"   create  (dry)  {summary[:58]}   -> {'Done' if done else 'TO DO'}")
        continue
    else:
        k = api("POST", "/rest/api/3/issue",
                {"fields": {"project": {"key": PROJECT}, "summary": summary,
                            "issuetype": {"name": "Task"}, "description": adf(paras)}})["key"]
        print(f"   created {k}  {summary[:58]}")
    if GO:
        api("POST", f"/rest/agile/1.0/sprint/{SPRINT}/issue", {"issues": [k]})
        api("PUT", f"/rest/api/3/issue/{k}", {"fields": {"assignee": {"accountId": MY_ID}}})
        if done:
            print(f"           -> {transition_to(k, 'Done')}")
    created.append(k)

for k in PRICING:
    if GO:
        api("PUT", f"/rest/api/3/issue/{k}", {"fields": {"assignee": {"accountId": IDRIS_ID}}})
        print(f"   assign  {k} -> {IDRIS_NAME}")
    else:
        print(f"   assign  (dry) {k} -> {IDRIS_NAME}")

if GO:
    print("\n== read back from Jira ==")
    for k in created + PRICING:
        f = api("GET", f"/rest/api/3/issue/{k}?fields=summary,status,assignee")["fields"]
        who = (f.get("assignee") or {}).get("displayName") or "UNASSIGNED"
        print(f"   {k:<12} {f['status']['name']:<13} {who:<18} {f['summary'][:50]}")
