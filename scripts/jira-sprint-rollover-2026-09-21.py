#!/usr/bin/env python3
"""Close the active INFRA sprint, backlog what is not done, open the sprint starting Mon 2026-09-21.

Then file exactly three tickets and put them in the new sprint:
  1. Doke   -- document on-prem cluster creation, and rewire the IaC it exposed
  2. Idris  -- RisingWave pipeline edge cases, dev -> QA
  3. Idris  -- RisingWave alerting

DRY-RUN BY DEFAULT. Pass --go to write.
Auth:  read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo

Closing a sprint is not cleanly reversible and it is visible to the whole team, so the dry
run prints the sprint it found, every issue it will move to the backlog, and the dates of
the sprint it will create. Read that list before passing --go.

Incomplete issues are moved to the backlog EXPLICITLY, before the close, rather than relying
on the close to relocate them. Jira's own completion dialog asks where they should go; the
API close does not, and its default is not worth discovering on a live board.
"""
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request

GO = "--go" in sys.argv

BASE = "https://usxpress.atlassian.net"
EMAIL = os.environ.get("JIRA_EMAIL", "doke@usxpress.com")
PROJECT = "INFRA"
BOARD = int(os.environ.get("JIRA_BOARD", "322"))

# Editable. Printed in the dry run so a wrong date is caught before the sprint exists.
SPRINT_START = "2026-09-21T13:00:00.000Z"   # Mon 21 Sep, 09:00 America/New_York
SPRINT_END = "2026-10-02T21:00:00.000Z"     # Fri 02 Oct, 17:00 America/New_York

DOKE = "doke@usxpress.com"
IDRIS = "ifagbemi@usxpress.com"


def die(msg):
    sys.exit(f"\n!! {msg}\n")


def get_token():
    t = os.environ.get("ATLASSIAN_TOKEN") or os.environ.get("CONFLUENCE_TOKEN")
    if not t:
        die("No token. Set it without putting it in shell history:\n"
            "   read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo")
    return t.strip()


AUTH = "Basic " + base64.b64encode(f"{EMAIL}:{get_token()}".encode()).decode()


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method, headers={
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
    """Markdown-ish text -> ADF, preserving single newlines as hard breaks.

    The shared helper in close-sprint3-tickets.py splits only on blank lines, so every
    bullet in a list collapses onto one line. Descriptions here carry lists that have to
    stay readable, so a single newline becomes a hardBreak node.
    """
    blocks = []
    for para in text.split("\n\n"):
        para = para.rstrip()
        if not para:
            continue
        content = []
        for i, line in enumerate(para.split("\n")):
            if i:
                content.append({"type": "hardBreak"})
            if line:
                content.append({"type": "text", "text": line})
        blocks.append({"type": "paragraph", "content": content})
    return {"type": "doc", "version": 1, "content": blocks}


def preflight():
    """Prove the token works before any mutation.

    Jira answers an unauthenticated issue read with 404 and an unauthenticated create with
    400 -- both read as permission problems rather than auth ones, which has cost a whole
    --go run before now."""
    s, r = api("GET", "/rest/api/3/myself")
    if s != 200:
        tok = os.environ.get("ATLASSIAN_TOKEN", "")
        print(f"!! cannot authenticate to {BASE} as {EMAIL}  (HTTP {s})")
        if len(tok) < 20:
            print(f"   ATLASSIAN_TOKEN is {len(tok)} characters -- that is not a token.")
        else:
            print("   Plausible length, so expired or revoked.")
            print("   Mint one: https://id.atlassian.com/manage-profile/security/api-tokens")
        sys.exit(1)
    print(f"authenticated as {r.get('displayName')} <{r.get('emailAddress', EMAIL)}>\n")


def account_id(email):
    s, r = api("GET", f"/rest/api/3/user/search?query={email}")
    if s != 200 or not r:
        print(f"  !! cannot resolve {email} ({s}) -- ticket will be left unassigned")
        return None
    exact = [u for u in r if (u.get("emailAddress") or "").lower() == email.lower()]
    pool = exact or r
    if len(pool) > 1:
        print(f"  !! {email} matched {len(pool)} users -- leaving unassigned rather than guessing")
        return None
    return pool[0]["accountId"]


def next_sprint_name(current):
    """Follow the board's own naming. 'UI Sprint 4' -> 'UI Sprint 5'."""
    m = re.match(r"^(.*?)(\d+)\s*$", current or "")
    if m:
        return f"{m.group(1)}{int(m.group(2)) + 1}"
    return f"Sprint from {SPRINT_START[:10]}"


# ─────────────────────────────────────────────────────────── the three tickets ──

TICKETS = [
    {
        "assignee": DOKE,
        "summary": "Document on-prem cluster creation end to end, and rewire the IaC it exposes",
        "labels": ["onprem", "iac", "documentation"],
        "desc": """Produce the documentation that lets someone other than the author create or rebuild an on-prem Talos cluster, and fix the infrastructure code that the exercise proved is wrong.

WHY NOW
QA2 (op-usxpress-qa-2) was stood up on 2026-09-17/18 specifically as a documentation rehearsal -- a throwaway cluster built by following our own instructions. It did not get as far as a running cluster, and every place it stopped is a real defect that would stop anyone else too.

PART 1 -- DOCUMENTATION
Finish the build book at docs/architecture/build-book/ (01-05 and 07 exist; 06 and 08-12 do not) and the step-by-step at QA2-STANDUP.md. It must name, for each step, which repo it lives in, what a person actually types, and which steps live in NO repo at all.

Five corrections the rehearsal already forced, which the old guidance got wrong:
- the state bucket is per AWS ACCOUNT; clusters are separated only by TF_STATE_KEY
- the lifecycle phase is console-only -- iaac-octopus-config does not manage Lifecycles-42
- no cluster has a <cluster>/octopus-worker secret; that instruction is for a thing that does not exist
- a new worker pool is created EMPTY; reuse the environment's existing pool
- ~33 Octopus project variables plus 9 in library sets are a WEB FORM, not code

PART 2 -- REWIRE THE CODE
Each of these blocked QA2 and will block the next cluster:

1. GitHub Actions OIDC provider is created per-cluster but is ACCOUNT-level. Second cluster in an existing account gets 409 EntityAlreadyExists and the whole apply fails. Worse in the other direction: `terraform destroy` on the first cluster DELETES the account's provider and breaks GitHub Actions federation for everything else in that account. Fix: gate on a variable defaulting true, read it as a data source when false, and include a `moved` block -- adding `count` re-addresses the resource, and without `moved` dev, QA and prod each plan to destroy and recreate it.

2. apply-bootstrap-perms.sh REPLACES the inline policy rather than appending, so a second cluster de-authorises the first. It also cannot run at all today: role octopus-usxpress holds 20 inline policies and AWS caps the aggregate at 10,240 bytes. Move to a managed policy.

3. octopus-create-qa2-vars.py copies only variables SCOPED to the source environment. Anything the source inherits from [ALL] silently arrives at the [ALL] default -- which is how QA2 planned 13 VMs instead of 4. [ALL] holds cp_cpus=2, cp_memory_mb=8192, disk_size_gb=50: dev-sized, and wrong for production in the dangerous direction. Add a pass that lists every TF_VAR_* the new environment resolves through [ALL] and makes the operator confirm each.

4. TF_USE_VARFILE: a -var-file outranks TF_VAR_* environment variables, so shipping a tfvars silently overrides the Octopus variables with no error anywhere. Pick one source of truth per environment and say which in the docs.

5. Upstream wip/iaac-talos/new-environment.sh and the scripts/octopus-*.py tools into iaac-talos. Today the Octopus half of a cluster build has no automation in any USX repo -- it exists only in one operator's personal working repo.

ACCEPTANCE
- a second cluster can be planned in an account that already holds one, with zero hand-edited IAM
- `terraform destroy` on one cluster provably does not remove an account-level resource another cluster depends on
- someone who was not present can follow the documentation to a running cluster, and the steps that are not automated are labelled as such rather than omitted

REFERENCES
docs/architecture/build-book/QA2-STANDUP.md
wip/iaac-talos/new-environment.sh
memory: octopus-all-scope-hides-inherited-values, one-account-one-cluster-assumption""",
    },
    {
        "assignee": IDRIS,
        "summary": "RisingWave pipeline: close the dev -> QA edge cases before a prod cutover date",
        "labels": ["risingwave", "cicd", "onprem"],
        "desc": """Make the RisingWave delivery path behave the same way on dev and QA, with a real payload, so "validated dev to QA" is a statement about evidence rather than intent.

WHY NOW
A prod cutover date is being asked for. The gate that made that dangerous is closed -- QA and prod are pinned to tag v0.5.6, so merging to main no longer deploys to production. What is not closed is the claim that the path is proven.

THE PROBLEM, STATED PLAINLY
Dev and QA are not the same mechanism, so a success on one says nothing about the other:
- op-usxpress-dev has ZERO Argo CD Applications and an empty app-risingwave namespace
- the QA path was proven on 2026-08-20 but carried a SMOKE payload (PIPELINE_DIR=smoke/), not the real pipeline
- arc-runners/risingwave-pipeline is defined on the op-qa branch and is NOT present on the QA cluster -- the CI runner the pipeline depends on may not exist where it is assumed to

EDGE CASES TO COVER, each of which has already bitten once
- two GHA roles, one pipeline repo: secret.yaml must assume the POC role (/risingwave/*), not the pipeline role (/risingwave-2/*, which is dev-only)
- a job's OIDC subject carries environment:<name> only if the job declares `environment:` -- without it, environment-scoped secrets resolve EMPTY and the run still goes green
- ExternalSecrets write PARTIAL secrets on failure: the pod then dies at container creation with RESTARTS 0, which no restart alert can see
- a failed Argo sync-hook Job makes every later sync a 0-second no-op replaying the original failure; compare startedAt with finishedAt before believing a failed sync
- risingwave-2 is DEV-ONLY and must never be promoted; QA and prod are always the `risingwave` namespace
- images must be digest-pinned: 515 of 517 ECR repositories grant org-wide push and there is no registry policy
- conventional commits drive releases -- no fix:/feat: prefix means no version bump, no new package, and a green workflow that shipped nothing

ACCEPTANCE
- the SAME non-smoke payload promotes dev -> QA through the SAME mechanism, demonstrated end to end
- the deployed artifact's digest is read off the running pod and matches the one the pipeline published
- each edge case above has either a test, a guard, or a written statement of why it cannot occur
- a prod cutover checklist exists whose every line is something that was actually exercised on QA

REFERENCES
memory: onprem-app-cicd, two-gha-roles-one-pipeline-repo, gha-oidc-needs-environment-claim, eso-writes-partial-secrets, failed-hook-job-makes-sync-a-noop, risingwave-onprem-has-no-promotion-gate
wip/iaac-talos-flux-cluster/PROMOTING-RISINGWAVE.md""",
    },
    {
        "assignee": IDRIS,
        "summary": "RisingWave alerting: deliver alerts to a human, platform and application split",
        "labels": ["risingwave", "observability", "alerting"],
        "desc": """Alerts on the on-prem clusters currently reach nobody. Build the delivery path, triage what is already firing, then add the RisingWave rules.

MEASURED ON op-usxpress-qa, 2026-09-18 -- this is QA, not inferred from dev
  Prometheus CR has NO .spec.alerting        -- firing alerts go nowhere
  no alertmanager pod in namespace prometheus
  21 firing, 8 of them for more than a week

ORDER MATTERS. Each step is blocked by the one above it.

1. TRIAGE BEFORE DELIVERY. Turning delivery on with an un-reviewed backlog trains everyone to mute the channel in week one. The 21 are not 21 problems:
   - the seven oldest all begin at 2026-07-14T17:57, INCLUDING Watchdog. Watchdog fires the moment Prometheus starts, so that timestamp is Prometheus's own boot -- those seven have been firing since start-up, not since an incident.
   - KubeProxyDown / KubeControllerManagerDown / KubeSchedulerDown are Talos static-pod false positives; the default scrape config cannot see them.
   - ClusterDNSUnreachable (critical, ours) fires because probe_success has NO SERIES -- there is no blackbox exporter. It reports a missing probe, not a DNS outage.
   - an alert whose label set contains the EXPORTER rather than the subject has a meaningless age: ten alerts reset their activeAt when kube-state-metrics restarted. Read job names and object timestamps, not activeAt.
   - KubeJobFailed has no time bound and failedJobsHistoryLimit only prunes when a NEW failure arrives, so a healthy CronJob keeps its last failures forever. Five 58-day-old etcd-backup Jobs were firing two alerts on 2026-09-18; deleting the Job objects cleared them, but our own EtcdSnapshotJobFailing rule needs a time bound so it cannot do this again.

2. BUILD THE SINK. This is the design decision, not a values change. The ~40 existing rules are PrometheusRules, so Alertmanager is what delivers them -- Grafana contact points only see rules authored inside Grafana. Recommended: Alertmanager as the sink, Grafana as the UI.

3. TEAMS CHANNEL. Note before committing to a date: Microsoft is retiring the Office 365 connector webhooks that Grafana's and Alertmanager's built-in Teams integrations were written against. The replacement is a Power Automate workflow, and some tenants block those. Confirm what our tenant accepts first.

4. ROUTE BY OWNER, which is what this work is for: platform and infrastructure alerts to the On-Prem team, application alerts to the RisingWave owners. The rules need labels that can express that split; they do not have them today.

5. A TEAMS CHANNEL IS NOT PAGING. The routing target of record is PagerDuty -> Freshservice, agreed with Steve Duck. Teams is a fine home for warnings; critical still needs the rotation.

6. RISINGWAVE RULES. wip/rw-alerting/ALERTS-TO-BUILD.md holds them, each derived from an outage that really happened, with three preconditions that must hold first (Alertmanager exists; RisingWave is actually scraped; the component label scheme is version-dependent -- gate on targets UP in Prometheus, not on a manifest existing).

NOT A BLOCKER ANY MORE
Grafana's HelmRelease on QA had been stalled since 14 July, so nothing committed under infrastructure/grafana/ reached the cluster for two months. Fixed and merged 2026-09-18 (PRs 151 and 152). Grafana itself was running the whole time -- it was Flux's grip on it that was broken.

ALSO WORTH KNOWING
81 rules are flagged as unable to fire. Treat that as an upper bound -- the extractor mishandles on(), ignoring(), group_left() and inverts absent(). Entries naming a real metric are credible, and certmanager_certificate_expiration_timestamp_seconds is among them, which means CERTIFICATE EXPIRY ALERTING DOES NOT WORK ON QA.

ACCEPTANCE
- a synthetic alert fires and arrives in the channel, timed
- every one of the 21 has a decision recorded: fix, silence with a reason, or delete
- a platform alert and an application alert demonstrably reach different destinations
- the check reports a sink: `bash scripts/check-alert-delivery.sh --context admin@op-usxpress-qa`

REFERENCES
wip/observability/FINDINGS-2026-08-21-alerts-reach-nobody.md
wip/observability/INFRA-1658-TRIAGE-2026-08-24.md
wip/onprem-observability/FINDINGS-2026-09-18-qa-grafana-stalled.md
wip/rw-alerting/ALERTS-TO-BUILD.md
existing epic INFRA-1632 (INFRA-1657 / 1658 / 1659) -- link rather than duplicate""",
    },
]


def main():
    print(f"== jira sprint rollover  [{'EXECUTING' if GO else 'DRY RUN -- pass --go to execute'}]\n")
    preflight()

    # ---------------------------------------------------------------- find it --
    s, r = api("GET", f"/rest/agile/1.0/board/{BOARD}/sprint?state=active")
    if s != 200:
        die(f"cannot list sprints on board {BOARD} (HTTP {s}): {r}\n"
            f"   Set JIRA_BOARD if 322 is not the INFRA board.")
    active = r.get("values", [])
    if len(active) != 1:
        die(f"expected exactly one active sprint on board {BOARD}, found {len(active)}: "
            f"{[x.get('name') for x in active]}\n   Resolve by hand -- this will not guess.")
    sprint = active[0]
    sid, sname = sprint["id"], sprint["name"]
    print(f"active sprint: {sname}  (id {sid})")

    # ------------------------------------------------------------- what is in --
    issues, start = [], 0
    while True:
        s, r = api("GET", f"/rest/agile/1.0/sprint/{sid}/issue"
                          f"?startAt={start}&maxResults=100&fields=summary,status,assignee")
        if s != 200:
            die(f"cannot read sprint {sid} issues (HTTP {s}): {r}")
        issues.extend(r.get("issues", []))
        start += len(r.get("issues", []))
        if start >= r.get("total", 0) or not r.get("issues"):
            break

    done, todo = [], []
    for i in issues:
        cat = ((i["fields"].get("status") or {}).get("statusCategory") or {}).get("key")
        (done if cat == "done" else todo).append(i)

    print(f"  {len(issues)} issue(s): {len(done)} done, {len(todo)} not done\n")
    print("-- staying (done) --")
    for i in done:
        print(f"   {i['key']:<12} {i['fields']['summary'][:70]}")
    print("\n-- moving to BACKLOG (not done) --")
    for i in todo:
        st = (i["fields"].get("status") or {}).get("name", "?")
        print(f"   {i['key']:<12} [{st:<12}] {i['fields']['summary'][:60]}")

    new_name = next_sprint_name(sname)
    print(f"\n-- then --")
    print(f"   close  {sname} (id {sid})")
    print(f"   create {new_name}   {SPRINT_START[:10]} -> {SPRINT_END[:10]}")
    for t in TICKETS:
        print(f"   ticket [{t['assignee']}] {t['summary'][:64]}")

    if not GO:
        print("\ndry run -- nothing written. Re-read the backlog list above, then pass --go.")
        return

    # ------------------------------------------------------------------ do it --
    print("\n-- moving to backlog --")
    for chunk in [[i["key"] for i in todo][n:n + 50] for n in range(0, len(todo), 50)]:
        if not chunk:
            continue
        s, r = api("POST", "/rest/agile/1.0/backlog/issue", {"issues": chunk})
        print(f"   {len(chunk)} issue(s): {'OK' if s in (200, 204) else f'FAIL {s} {r}'}")

    print("-- closing sprint --")
    s, r = api("POST", f"/rest/agile/1.0/sprint/{sid}", {"state": "closed"})
    if s not in (200, 204):
        die(f"could not close sprint {sid} (HTTP {s}): {r}\n"
            f"   The backlog move above DID run -- check the board before retrying.")
    print(f"   closed {sname}")

    print("-- creating sprint --")
    s, r = api("POST", "/rest/agile/1.0/sprint", {
        "name": new_name, "startDate": SPRINT_START, "endDate": SPRINT_END,
        "originBoardId": BOARD})
    if s not in (200, 201):
        die(f"could not create sprint (HTTP {s}): {r}")
    new_id = r["id"]
    print(f"   created {new_name} (id {new_id})")

    print("-- creating tickets --")
    created = []
    for t in TICKETS:
        fields = {
            "project": {"key": PROJECT},
            "summary": t["summary"],
            "description": adf(t["desc"]),
            "issuetype": {"name": "Task"},
            "labels": t.get("labels", []),
        }
        aid = account_id(t["assignee"])
        if aid:
            fields["assignee"] = {"accountId": aid}
        s, r = api("POST", "/rest/api/3/issue", {"fields": fields})
        if s not in (200, 201):
            print(f"   !! create failed {s}: {r}")
            continue
        key = r["key"]
        created.append(key)
        print(f"   {key}  [{t['assignee']}]  {t['summary'][:56]}")

    if created:
        print("-- adding to sprint --")
        s, r = api("POST", f"/rest/agile/1.0/sprint/{new_id}/issue", {"issues": created})
        print(f"   {len(created)} issue(s) -> {new_name}: "
              f"{'OK' if s in (200, 204) else f'FAIL {s} {r}'}")

    print(f"\ndone. {BASE}/jira/software/c/projects/{PROJECT}/boards/{BOARD}")


if __name__ == "__main__":
    main()
