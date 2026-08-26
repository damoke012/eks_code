#!/usr/bin/env python3
"""Act on the 2026-08-25 review of Idris's board: comment, close, and file the carrier.

Dry run by default. Nothing is written without --go.

Token: read from scripts/push-to-confluence.sh, which already holds it (gitignored,
never committed, chmod 600). Same token that was pasted into the session; it still
needs rotating afterwards either way.
"""
import base64, json, os, re, sys, urllib.request, urllib.error

BASE = "https://usxpress.atlassian.net"
EMAIL = os.environ.get("JIRA_EMAIL", "doke@usxpress.com")
GO = "--go" in sys.argv
HERE = os.path.dirname(os.path.abspath(__file__))

def token():
    t = os.environ.get("ATLASSIAN_TOKEN")
    if t: return t.strip()
    p = os.path.join(HERE, "push-to-confluence.sh")
    m = re.search(r"CONFLUENCE_TOKEN='([^']+)'", open(p).read())
    if not m: sys.exit("no token in %s and ATLASSIAN_TOKEN unset" % p)
    return m.group(1)

AUTH = "Basic " + base64.b64encode(f"{EMAIL}:{token()}".encode()).decode()

def api(method, path, body=None):
    req = urllib.request.Request(BASE + path, method=method,
        headers={"Authorization": AUTH, "Accept": "application/json",
                 "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body is not None else None)
    try:
        r = urllib.request.urlopen(req, timeout=45)
        raw = r.read()
        return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try: return e.code, json.loads(raw)
        except Exception: return e.code, {"raw": raw.decode("utf-8", "replace")[:400]}

def adf(text):
    """Markdown-ish plain text -> Atlassian Document Format. Only what we use:
    paragraphs, and lines starting with '- ' as a bullet list."""
    content, bullets = [], []
    def flush():
        if bullets:
            content.append({"type": "bulletList", "content": [
                {"type": "listItem", "content": [
                    {"type": "paragraph", "content": [{"type": "text", "text": b}]}]}
                for b in bullets]})
            bullets.clear()
    for line in text.strip().split("\n"):
        s = line.strip()
        if not s: flush(); continue
        if s.startswith("- "): bullets.append(s[2:]); continue
        flush()
        content.append({"type": "paragraph", "content": [{"type": "text", "text": s}]})
    flush()
    return {"type": "doc", "version": 1, "content": content}

def done_transition(key):
    s, r = api("GET", f"/rest/api/3/issue/{key}/transitions")
    if s != 200: return None, r
    for t in r.get("transitions", []):
        cat = (t.get("to") or {}).get("statusCategory", {}).get("key")
        if cat == "done": return t, r.get("transitions", [])
    return None, [t["name"] for t in r.get("transitions", [])]

CLOSURES = {
"INFRA-1626": """Closing: the blocker this ticket names no longer exists.

The Talos configuration is in AWS Secrets Manager at op-usxpress-prod/talosconfig (account 937464026810, us-east-2), and a working kubeconfig is rebuilt from it non-interactively:

scripts/onprem-prod-kubeconfig.sh ops-controller

Proven 2026-08-25: 13 op-prod nodes returned, and lib-onprem-ctx.sh now resolves op-prod by endpoint so every script in the toolkit reaches it. The equivalent config for dev and QA has been available throughout.

The upgrade itself is not closed by this - it continues under the carrier ticket referenced below, which now owns the Talos/Kubernetes upgrade for all three on-prem clusters.""",

"INFRA-1591": """Closing: both halves are delivered, and the half that was the point was delivered by the platform.

The reusable pattern - the ticket's actual goal, "rather than wire this one-off for RisingWave, build a reusable platform SSO pattern" - shipped 2026-08-25 as Entra OIDC on Argo CD across op-dev, op-qa and op-prod. No Dex anywhere, so it generalises to any application without a per-app Dex deployment. App registration "Argo CD On-Prem" 42dc0c33-4c56-47a5-b207-d119272997aa.

RisingWave as first consumer - delivered by Idris: Dex embedded in the RisingWave console, QA dashboard SSO wired 2026-08-13, one Entra app e112d6ce-cc60-4884-9898-8fcc5b78b0b1 shared by dev and QA.

One finding worth carrying forward rather than assuming, because it is not obvious and it cost most of a day to establish:

This tenant does NOT emit a groups claim to the confidential (web) OIDC flow. Verified against every setting: groupMembershipClaims SecurityGroup and ApplicationGroup, groups present in optionalClaims.idToken, no claims-mapping policy on the service principal, 42 groups so well under the overage threshold, and emit_as_roles not set. It does emit groups to the public-client PKCE flow, for the same user in the same minute - so the behaviour depends on the flow, not on configuration.

If the RisingWave console's Dex config keys authorisation on group membership, it is either not doing group-based authorisation at all or relying on something that will not hold. The route around it is an Entra app role and the roles claim, which is issued from appRoleAssignments on the service principal and works in both flows. Procedure: .claude/skills/entra-authz-claims/SKILL.md in the eks_code repo.

Any remaining RisingWave-console-specific issue should be its own ticket rather than keeping this one open.""",

"INFRA-1489": """Closing: the design this ticket gates has been superseded, so signing it off would record approval of something we are not going to run.

It gates feat/onprem-rw2-adaptation and ONPREM_CICD.md - the in-cluster ARC self-hosted runner design, where the execute job runs inside the cluster to reach risingwave-frontend:4567 without external ingress.

The on-prem delivery standard adopted 2026-08-25 is different in kind: build once on GitHub-hosted runners, push to the shared ECR by digest, and let Argo CD apply it from the application repo's deploy/ overlays. No in-cluster runner, no external ingress needed, and the promotion guarantee comes from the digest rather than from the pipeline. This path is now the standard for every net-new on-prem deployment; DX/MageRunner is used only for existing workloads being moved on-prem.

The decision about what happens to the existing dev ARC-runner pipeline is INFRA-1644 and is carried by the carrier ticket referenced below. This ticket closes against that decision rather than waiting on it.""",

"INFRA-1490": """Closing with INFRA-1489, for the same reason: the mechanism it configures belongs to a superseded design.

The GitHub Environment pipeline-approval exists to pause the approve job in pipeline.yaml. Under the delivery standard the human gate is different and already in place: promotion to production is a pull request moving the same image digest into deploy/overlays/prod/, followed by a manual sync in Argo CD. Two gates, both recorded in git and in the Argo CD history, neither of which needs a GitHub Environment.

Production Argo CD Applications deliberately carry no automated sync policy. A merge does not deploy to production; a person does.

If the dev pipeline survives the INFRA-1644 decision in a form that still uses pipeline.yaml's approve job, re-open this rather than re-filing.""",

"INFRA-1488": """Closing on the delivered half, with the remainder folded into the carrier ticket referenced below.

Delivered, as a platform capability rather than a RisingWave one. The ticket asked for "a documented, repeatable way to declare and consume secrets" so that app teams stop going one-off through Tim or Idris. That exists now and applies to every application on the on-prem clusters:

- External Secrets Operator and a ClusterSecretStore on all three clusters
- per-environment secret paths in AWS Secrets Manager, op-usxpress-<env>/<app>/<name>
- the ownership line written down in the onboarding document: the platform owns secret DELIVERY, the application team owns secret VALUES
- an ExternalSecret in the app's own deploy/ overlay is how a team declares what it needs

Not delivered, and folded rather than dropped: RisingWave and postgres user creation through the SQL pipeline. Under the delivery standard this is no longer a "pattern" question - it is an Argo CD sync hook Job in the application's own deploy/ directory, which re-runs on every sync and whose logs land in the Argo CD UI. That scope now sits on the carrier ticket.

One caution that belongs with this work, from INFRA-1652: a green ExternalSecret proves the sync ran, not that the value is correct. And secretKeyRef environment variables resolve at POD CREATION - a rotated secret never reaches a running pod, and a container restart replays the old value. The QA postgres password drifted for nine days exactly that way.""",
}

CARRIER = {
 "summary": "On-prem platform pickup from the RisingWave board review (2026-08-25)",
 "description": """Carrier for three scopes that came out of the 2026-08-25 review of the RisingWave board. They are unrelated to one another and each can be split into its own ticket at any point; they are together because they all moved off Idris in the same conversation.

Full review: wip/onprem-app-cicd/IDRIS-BOARD-REVIEW-2026-08-25.md in the eks_code repo.

SCOPE 1 - Kubernetes and Talos Linux upgrade, dev/QA/prod. Moved from INFRA-1628, which was assigned to Idris. This is platform work and Idris is now on the application side of the split. The reworked ladder from 2026-08-04 stands: Talos v1.11.1 to 1.13, Kubernetes v1.32.0 to 1.35. All three clusters confirmed at v1.32.0 on 2026-08-25. INFRA-1626, which asked for access to the Talos configuration, is closed - the config is in Secrets Manager and scripts/onprem-prod-kubeconfig.sh rebuilds a kubeconfig from it.

SCOPE 2 - RisingWave and postgres user creation through the SQL pipeline. The undelivered half of INFRA-1488. Under the delivery standard this is an Argo CD sync hook Job in the application's deploy/ directory, not a platform pattern. Carried here so it is not lost when 1488 closes; hand it back to the application team once containerisation lands.

SCOPE 3 - Decide the future of the dev ARC-runner pipeline (INFRA-1644). INFRA-1489 and INFRA-1490 both closed against this decision, so it now needs an owner or those closures point at nothing. The question: the risingwave-pipeline repo plus its in-cluster ARC runner reaches risingwave-2 on dev only, and the repo has diverged from the live cluster - 400-sink.rw defines sinks dev does not run. Either retire it in favour of the standard path, or state what it is for.

Acceptance: each scope either delivered, or split out into its own ticket with an owner. This ticket should not outlive the three.""",
}

def main():
    print("== authenticating")
    s, me = api("GET", "/rest/api/3/myself")
    if s != 200: sys.exit("auth failed: %s %s" % (s, me))
    print("   %s <%s>\n" % (me.get("displayName"), me.get("emailAddress")))

    print("== carrier ticket")
    print("   summary: %s" % CARRIER["summary"])
    if GO:
        s, r = api("POST", "/rest/api/3/issue", {"fields": {
            "project": {"key": "INFRA"}, "issuetype": {"name": "Task"},
            "summary": CARRIER["summary"], "description": adf(CARRIER["description"]),
            "assignee": {"accountId": me["accountId"]}}})
        if s not in (200, 201): sys.exit("   !! create failed: %s %s" % (s, r))
        carrier = r["key"]; print("   created %s" % carrier)
    else:
        carrier = "INFRA-<new>"; print("   DRY RUN - would create, assigned to %s" % me.get("displayName"))
    print()

    for key, body in CLOSURES.items():
        s, i = api("GET", f"/rest/api/3/issue/{key}?fields=summary,status")
        if s != 200: print("!! %s unreadable: %s" % (key, i)); continue
        cur = i["fields"]["status"]["name"]
        print("== %s [%s] %s" % (key, cur, i["fields"]["summary"][:60]))
        text = body.replace("the carrier ticket referenced below", carrier)
        if not GO:
            t, alt = done_transition(key)
            print("   would comment (%d chars) and transition via %r"
                  % (len(text), t["name"] if t else "NO DONE TRANSITION: %s" % alt))
            continue
        s, r = api("POST", f"/rest/api/3/issue/{key}/comment", {"body": adf(text)})
        print("   comment: %s" % ("ok" if s in (200, 201) else "FAILED %s %s" % (s, r)))
        t, alt = done_transition(key)
        if not t: print("   !! no done-category transition available: %s" % alt); continue
        s, r = api("POST", f"/rest/api/3/issue/{key}/transitions", {"transition": {"id": t["id"]}})
        print("   transition %-14s %s" % (t["name"], "ok" if s in (200, 204) else "FAILED %s %s" % (s, r)))

    print("\n%s" % ("done." if GO else "DRY RUN - nothing written. Re-run with --go"))

main()
