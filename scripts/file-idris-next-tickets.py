#!/usr/bin/env python3
"""File the tickets the 2026-08-25 board review found missing, in priority order.

Dry run by default; --go writes. Priority is encoded in the order they are created
and stated in each description, because Jira priority fields drift and a sentence
does not.
"""
import base64, json, os, re, sys, urllib.request, urllib.error

BASE="https://usxpress.atlassian.net"; EMAIL=os.environ.get("JIRA_EMAIL","doke@usxpress.com")
GO="--go" in sys.argv
HERE=os.path.dirname(os.path.abspath(__file__))
IDRIS="712020:d5331c18-29a9-4603-a779-c40081c61521"
RW_EPIC="INFRA-1473"

def token():
    t=os.environ.get("ATLASSIAN_TOKEN")
    if t: return t.strip()
    m=re.search(r"CONFLUENCE_TOKEN='([^']+)'", open(os.path.join(HERE,"push-to-confluence.sh")).read())
    if not m: sys.exit("no token")
    return m.group(1)
AUTH="Basic "+base64.b64encode(f"{EMAIL}:{token()}".encode()).decode()

def api(m,p,b=None):
    r=urllib.request.Request(BASE+p,method=m,headers={"Authorization":AUTH,"Accept":"application/json","Content-Type":"application/json"},
                             data=json.dumps(b).encode() if b is not None else None)
    try:
        x=urllib.request.urlopen(r,timeout=45); raw=x.read(); return x.status,(json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw=e.read()
        try: return e.code,json.loads(raw)
        except Exception: return e.code,{"raw":raw.decode("utf-8","replace")[:400]}

def adf(text):
    content,bul=[],[]
    def flush():
        if bul:
            content.append({"type":"bulletList","content":[
                {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":b}]}]} for b in bul]})
            bul.clear()
    for line in text.strip().split("\n"):
        s=line.strip()
        if not s: flush(); continue
        if s.startswith("- "): bul.append(s[2:]); continue
        flush(); content.append({"type":"paragraph","content":[{"type":"text","text":s}]})
    flush()
    return {"type":"doc","version":1,"content":content}

TICKETS=[
 dict(pri=1, itype="Story", parent=RW_EPIC,
  summary="P1 — Containerise the RisingWave workload for the on-prem delivery path",
  desc="""Priority 1 of the RisingWave application work. Everything downstream waits on this, and it is the one piece the platform genuinely cannot supply.

Context. The on-prem delivery standard adopted 2026-08-25 is: build once in GitHub Actions on a GitHub-hosted runner, push to the shared ECR by DIGEST, then let Argo CD apply it from the application repo's deploy/ overlays. That path is proven end to end on op-usxpress-qa. It needs a container image, and RisingWave does not have one yet.

Acceptance criteria.
- A Dockerfile in the application repository that builds the workload.
- A GitHub Actions workflow that builds on a GitHub-hosted runner and pushes to ECR by digest via the GitHub OIDC role. Copy app-template/service or app-template/job rather than starting from scratch.
- The image runs in an app-<name> namespace under PodSecurity "restricted" and the ambient mesh.
- Nothing environment-specific is baked in. If a value differs between QA and prod it belongs in a ConfigMap in the overlay or in Secrets Manager, not in the image. An inlined dev- topic prefix will not fail loudly in QA; it will succeed against the wrong thing.

Blocked on, from the platform side: the existing GitHub OIDC push role is scoped to ONE repository ARN, risingwave/etl-pipeline. A second image needs its own ECR repository and a widened or additional role. Tracked separately - do not try to self-serve it.

Reference: the orientation doc, and wip/onprem-app-cicd/ONBOARDING.md in the eks_code repo."""),

 dict(pri=2, itype="Story", parent=RW_EPIC,
  summary="P2 — deploy/ base and per-environment overlays for the containerised RisingWave workload",
  desc="""Priority 2. Depends on P1 (containerisation).

The manifests that Argo CD applies live in the application repository, not in the platform repo. Argo CD reads them from deploy/ and applies them into app-<name>.

Acceptance criteria.
- deploy/base with the Deployment or Job, Service, and ConfigMaps.
- deploy/overlays/qa and deploy/overlays/prod.
- Images pinned by DIGEST in every overlay. Kyverno refuses both :latest and :v1.2.3 - a tag can be moved and a digest cannot, and the promotion guarantee rests entirely on that.
- Credentials referenced through an ExternalSecret, never inline. The platform owns secret DELIVERY, the application team owns the VALUES.
- Promotion to prod is a pull request moving the SAME digest into deploy/overlays/prod, then a manual sync in Argo CD. Nothing is rebuilt between environments.

Note on INFRA-1635: that ticket covers overlays for the ETL smoke payload and its PIPELINE_DIR still points at it. This is the containerised workload, which is a different artefact.

Two things that will cost you a day if nobody says them. A green sync is not a working deploy - Argo CD reports that Kubernetes accepted the manifests and the pods became ready, not that the work happened. And secretKeyRef environment variables resolve at POD CREATION, so a rotated secret never reaches a running pod and a restart replays the old value; the QA postgres password drifted for nine days exactly that way."""),

 dict(pri=3, itype="Task", parent=RW_EPIC,
  summary="P3 — Explain the 238 SIGSEGV restarts on risingwave-meta-default-0 before anything is promoted to prod",
  desc="""Priority 3. This is a gate on INFRA-1475 (RisingWave in production), not a curiosity.

Observed on op-usxpress-qa, 2026-08-13: meta 238 restarts, compute 310, frontend 276, compactor 313 - all then stable for roughly 30 hours. Something crash-looped for about two days and whatever resolved it is not written down anywhere.

Why it matters. We do not know whether the fix was a configuration change, a resource limit, a dependency coming up, or luck. Promoting a shape whose failure mode is undocumented to production means we will meet it again there, with no idea what to do.

Acceptance criteria.
- The cause named, with evidence - previous container logs, events, resource pressure, or the change that stopped it.
- Either a fix recorded in the source repository, or a written statement of why the current configuration is safe to promote.
- If the cause cannot be established, say so explicitly. That is a legitimate answer and it changes the prod decision; a silent unknown does not."""),

 dict(pri=4, itype="Task", parent=RW_EPIC,
  summary="P4 — Confirm RisingWave console SSO does not depend on the Entra groups claim",
  desc="""Priority 4. Comes out of the INFRA-1591 closure and needs a home now that the ticket is closed.

The finding. This Entra tenant does NOT emit a groups claim to the confidential (web) OIDC flow. Established 2026-08-25 against every setting there is: groupMembershipClaims SecurityGroup and ApplicationGroup, groups present in optionalClaims.idToken, no claims-mapping policy on the service principal, 42 groups so nowhere near the overage threshold, and emit_as_roles not set. It DOES emit groups to the public-client PKCE flow, for the same user in the same minute - so the behaviour depends on the flow, not on configuration.

The RisingWave console authenticates through Dex embedded in the console, against Entra app e112d6ce-cc60-4884-9898-8fcc5b78b0b1, shared by dev and QA.

Acceptance criteria.
- Establish whether the console's Dex configuration authorises on group membership at all.
- If it does not, say so and close - there is nothing to fix.
- If it does, it is either not working as intended or resting on something that will not hold. Migrate to an Entra app role and the roles claim, which is issued from appRoleAssignments on the service principal and works in BOTH flows.

Procedure, including the app-role route and the checks: .claude/skills/entra-authz-claims/SKILL.md in the eks_code repo. Argo CD now uses exactly this pattern on all three clusters."""),

 dict(pri=5, itype="Task", parent=None,
  summary="P5 — Exercise role:app-viewer on op-qa (acceptance test for INFRA-1639)",
  desc="""Priority 5, and small - about five minutes - but it is the acceptance criterion for INFRA-1639, which cannot close without it.

Argo CD SSO went live on all three on-prem clusters on 2026-08-25. Everything verified so far is platform-admin access. Nobody has signed in as an application-team member, and that is what the ticket is actually about.

Acceptance criteria.
- Sign in at https://argocd.op-qa.usxpress.io and see the risingwave-etl Application, its resource tree, and the sync-hook Job's logs.
- Confirm nothing outside the apps project is visible.
- Confirm there is NO sync control on op-prod, and there IS one on op-qa. Promotion to production is human-initiated by the platform, by design - if a Sync button appears on prod, the policy is wrong in a way none of the automated checks would catch.
- Optionally run the deny checks directly, which work even on a cluster with no Applications:

argocd login argocd.op-qa.usxpress.io --sso --grpc-web --sso-launch-browser=false
bash scripts/argocd-can-i.sh op-qa --role app-viewer
bash scripts/argocd-can-i.sh op-prod --role app-viewer

--grpc-web is required because TLS terminates at the Istio gateway. --sso-launch-browser=false is for WSL, which has no xdg-open."""),
]

def main():
    s,me=api("GET","/rest/api/3/myself")
    if s!=200: sys.exit("auth failed %s %s"%(s,me))
    print("== authenticated as %s\n"%me.get("displayName"))
    created=[]
    for t in TICKETS:
        print("P%d  %-9s %s"%(t["pri"], t["itype"], t["summary"][:78]))
        if not GO:
            print("    DRY RUN - parent=%s assignee=Idris\n"%(t["parent"] or "none")); continue
        fields={"project":{"key":"INFRA"},"issuetype":{"name":t["itype"]},
                "summary":t["summary"],"description":adf(t["desc"]),
                "assignee":{"accountId":IDRIS}}
        if t["parent"]: fields["parent"]={"key":t["parent"]}
        s,r=api("POST","/rest/api/3/issue",{"fields":fields})
        if s not in (200,201) and t["parent"]:
            print("    parent rejected, retrying without: %s"%str(r)[:120])
            fields.pop("parent"); s,r=api("POST","/rest/api/3/issue",{"fields":fields})
        if s in (200,201):
            print("    created %s\n"%r["key"]); created.append((t["pri"],r["key"],t["summary"]))
        else:
            print("    !! FAILED %s %s\n"%(s,str(r)[:250]))
    if created:
        print("== created, in priority order")
        for p,k,su in created: print("   P%d  %-11s %s"%(p,k,su[:70]))
    print("\n%s"%("done."if GO else"DRY RUN - re-run with --go"))
main()
