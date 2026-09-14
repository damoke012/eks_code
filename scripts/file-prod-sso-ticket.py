#!/usr/bin/env python3
"""File the op-usxpress-prod SSO ticket to INFRA, and print the key.

QA got AWS SSO cluster access on 2026-09-14 (iaac-talos #65). Prod passes every
cluster-side pre-flight but nobody can use it: the usx-on-prem-admins permission
set EXISTS in 937464026810 and is NOT ASSIGNED, so GetRoleCredentials returns
ForbiddenException. Enabling the apiserver flag first would change a prod control
plane to open a door with no key -- hence the ordering in the ticket.

Token comes from scripts/push-to-confluence.sh, same as the other Jira filers.
Read-only until the final POST, which is gated on a typed confirmation.

    python3 scripts/file-prod-sso-ticket.py --dry-run
    python3 scripts/file-prod-sso-ticket.py
"""
import base64
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
EMAIL = "doke@usxpress.com"
PROJECT = "INFRA"
SITE = "https://usxpress.atlassian.net"

TOKEN = ""
for ln in (REPO_ROOT / "scripts/push-to-confluence.sh").read_text().splitlines():
    if ln.startswith("CONFLUENCE_TOKEN="):
        TOKEN = ln.split("=", 1)[1].strip().strip('"').strip("'")
        break
if not TOKEN:
    sys.exit("ERROR: no token in scripts/push-to-confluence.sh")
AUTH = "Basic " + base64.b64encode(f"{EMAIL}:{TOKEN}".encode()).decode()

SUMMARY = "Enable AWS SSO cluster access on op-usxpress-prod (INFRA-1661)"

# Plain paragraphs and bullet lists only -- no markdown converter needed, and
# nothing here depends on a heredoc surviving a terminal paste.
PARAS = [
    "QA gained AWS SSO cluster access on 2026-09-14 via iaac-talos #65, which adds "
    "--authentication-token-webhook-config-file to kube-apiserver. Production does not have it. "
    "The cluster side of prod is already complete; the blocker is an Identity Center assignment.",

    "Verified on prod 2026-09-14, read-only:",
]
BULLETS_STATE = [
    "aws-iam-authenticator DaemonSet 3/3 Ready, 20 days, on the control-plane nodes",
    "/var/lib/aws-iam-authenticator/kubeconfig.yaml present on all three CPs "
    "(10.10.82.186, 10.10.82.187, 10.10.82.188), 1909 bytes, written 2026-08-24",
    "kube-system/aws-auth maps prod's own ARN, "
    "arn:aws:iam::937464026810:role/AWSReservedSSO_usx-on-prem-admins_837df2a43495aaf1",
    "kube-apiserver has NO --authentication-token-webhook-config-file on any of the three nodes",
    "A profile assuming usx-on-prem-admins fails at login: ForbiddenException, No access, "
    "from GetRoleCredentials. The role exists but is not assigned.",
]
PARAS_2 = [
    "The role existing is not the same as the role being assigned. aws iam list-roles shows it "
    "because the caller can read IAM in that account, which says nothing about entitlement.",

    "Do these in order. Enabling the flag before the assignment exists would change a production "
    "control plane and grant nobody anything, with no way to tell whether it worked:",
]
BULLETS_STEPS = [
    "Assign the usx-on-prem-admins permission set in AWS Identity Center for the prod account "
    "937464026810, to whoever should hold routine prod cluster access. Identity Center lives in "
    "the management account.",
    "Prove it: aws sso login --profile op-prod, then aws sts get-caller-identity --profile op-prod "
    "must return an ARN ending AWSReservedSSO_usx-on-prem-admins_837df2a43495aaf1/<user>.",
    "Re-run the per-node pre-flight with talosctl ls -l /var/lib/aws-iam-authenticator against "
    "every prod control-plane IP. kube-apiserver will not start if that file is missing, and the "
    "VIP only answers for one node, so one listing is not the population.",
    "Add the Octopus project variable TF_VAR_enable_aws_iam_authenticator = true scoped to "
    "production on iaac-talos. The envs/*.tfvars line does nothing; Octopus never reads -var-file.",
    "Deploy iaac-talos to production. TfApply is true for production, so it applies immediately.",
    "Verify: all three kube-apiserver pods back 1/1 with a fresh age, the flag present with the "
    "host path /var/lib/aws-iam-authenticator/kubeconfig.yaml, and kubectl auth whoami returning "
    "sso:<user> with group onprem-platform-admins.",
]
PARAS_3 = [
    "Risk and rollback: the only failure mode that costs a control plane is a missing webhook "
    "file, which the pre-flight rules out. x509 authentication is unaffected either way, so the "
    "break-glass kubeconfig rebuilt from op-usxpress-prod/talosconfig in Secrets Manager remains "
    "a working path into the cluster.",

    "Note the mapping differs per cluster. QA maps op-qa-platform-admin; prod maps "
    "usx-on-prem-admins; the ARN suffix is generated per account and must never be copied between "
    "clusters. Dev is in the same state as prod was and needs the same treatment.",
]


def adf():
    content = []
    for p in PARAS:
        content.append({"type": "paragraph", "content": [{"type": "text", "text": p}]})
    content.append(_list(BULLETS_STATE))
    for p in PARAS_2:
        content.append({"type": "paragraph", "content": [{"type": "text", "text": p}]})
    content.append(_list(BULLETS_STEPS))
    for p in PARAS_3:
        content.append({"type": "paragraph", "content": [{"type": "text", "text": p}]})
    return {"type": "doc", "version": 1, "content": content}


def _list(items):
    return {"type": "bulletList", "content": [
        {"type": "listItem", "content": [
            {"type": "paragraph", "content": [{"type": "text", "text": i}]}]}
        for i in items]}


def api(method, path, body=None):
    req = urllib.request.Request(
        SITE + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": AUTH, "Accept": "application/json",
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        sys.exit(f"ERROR {e.code} on {method} {path}\n{e.read()[:600].decode(errors='replace')}")


# Jira reports an unauthorised read as 404 and an unauthorised create as 400 "the
# target project doesn't exist" -- neither says "bad token". Prove the token first.
me = api("GET", "/rest/api/3/myself")
print(f"authenticated as {me.get('emailAddress') or me.get('displayName')}")
proj = api("GET", f"/rest/api/3/project/{PROJECT}")
print(f"project {proj['key']} ({proj['id']}) {proj['name']}")

payload = {"fields": {"project": {"key": PROJECT}, "summary": SUMMARY,
                      "issuetype": {"name": "Task"}, "description": adf()}}

if "--dry-run" in sys.argv:
    print("\n--- DRY RUN, nothing filed ---")
    print(SUMMARY)
    for b in BULLETS_STEPS:
        print("  step:", b[:100])
    sys.exit(0)

ans = input(f"\nfile '{SUMMARY}' to {PROJECT}? type yes: ")
if ans != "yes":
    sys.exit("aborted, nothing filed.")

issue = api("POST", "/rest/api/3/issue", payload)
print(f"\nfiled {issue['key']}  {SITE}/browse/{issue['key']}")
print("API-created tickets land in the BACKLOG, not the active sprint -- move it if it is for now.")
