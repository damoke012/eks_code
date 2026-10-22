---
name: proxy-is-not-the-property
description: The recurring self-inflicted error — measuring something adjacent to the property in question and reporting the proxy's answer as the property's; eight instances, each reversed by one direct check. Instance 8: a diagnostic script is itself an instrument, and running it against a KNOWN-GOOD machine is what exposes its proxies — review did not
metadata:
  type: feedback
---

Repeatedly, a confident wrong answer has come from measuring a proxy instead of the thing.
The count in this line kept going stale, so it is gone; the instances below are the record:

| Question | Proxy used | Verdict | Direct check that reversed it |
|---|---|---|---|
| Is master's SQL parameterised? | count of `%VAR%` tokens | "Idris regressed Tim's work" | reading the file — `secret kafka_api_key` scores zero `%` and is *more* parameterised |
| Which bucket did Terraform build? | AWS resource tags | "TF built the empty one" | creation dates + the IRSA policy's `Resource` list — the *untagged* bucket is TF's; the provider sets no `default_tags` |
| Are there unguarded DROPs? | `git grep` without `-P` | "zero findings" | `grep -rPn` — the lookahead had been silently ignored |
| Does op-prod have Istio Gateways? | `kubectl get gateway` | zero rows | `gateways.networking.istio.io` — it had resolved the Gateway API CRD instead |
| Is RisingWave already wired into prod's infra.yaml? | substring `risingwave-onprem` | "already wired — nothing to do" | parsing the documents — the match was inside the header comment *"does not exist in iaac-risingwave-onprem yet"* |

**Why:** every one of these produced a *clean, confident* result. Nothing errored. The proxy
answered its own question correctly and the answer was attributed to a different question.
This is the same family as [[adjacent-step-green-signals]] and
[[transport-failure-not-a-verdict]], but self-inflicted at the point of measurement rather
than inherited from a tool.

**How to apply:** before reporting a property, name the direct evidence for it. Tags are not
provenance — creation time and the policy that references the resource are. A token count is
not parameterisation — the file is. An empty result is only absence once the selector and the
resource kind are confirmed to resolve. When a proxy is the only thing available, say which
proxy was used and what it cannot see. Related:
[[eso-secretsynced-not-content-check]], [[merged-defect-authorizes-itself]].

**Instance 5 — 2026-09-01, and the first inside a guard written for this class.**
`setup-octopus-rw-prod.py` wrote QA's state bucket `lazy-tf-state-425rbol87rmn6c7m` into
RisingWave's **production** scope. Two of my own checks passed over it:

- the foreign-literal gate matched **account IDs** (`527101283767`) — but a bucket name
  does not contain its account, so the QA bucket read as clean;
- the post-write read-back matched **names present in production scope**, never values,
  and printed "Verified: all 10 are production-scoped".

Cost: prod deploy 0.5.6 died at `terraform init` with 403 HeadObject from the prod worker
against a QA-account bucket. Prod's bucket is `lazy-tf-state-ipp58n854uhpw13x`.

**How to apply:** when a value is an *identifier that resolves to something* — a bucket, an
ARN, an issuer, a role name — the environment check must test what it resolves to, or list
the other environments' identifiers literally. And a write-verify compares VALUES; confirming
the key is present is the proxy, not the property. See [[terraform-state-bucket-is-per-account]].

**Instance 6 — 2026-09-02. A PR description is a proxy for its diff.**
Reviewed Idris's `risingwave-pipeline` PR #21 from the PR page and raised two blockers that
the diff did not support:

- "a placeholder digest is being merged into the production overlay" — came from the PR
  body's **Follow-up / rollout prerequisites** list ("Replace the production placeholder
  digest through the normal promotion flow"). That list describes work *not in the PR*. The
  diff touches no digest at all.
- "four blockers were answered into gitignored files" — the body listed them as rollout
  prerequisites, which is the honest disposition, not a claim of completion.

Meanwhile the diff's actual headline was invisible from the page: both overlays moved
`PIPELINE_DIR` from `/pipeline/smoke` to `/pipeline/pipelines`, making a
script-hardening PR the **first real cutover on QA and prod at once**. Two lines in a
ConfigMap, +2/-1 per file, and the file list alone did not show it.

**How to apply:** a PR title, body, summary and file-name list are all proxies. `gh pr diff`
is the property, it is one command, and no finding gets raised before it has been read. A
follow-up list is not a change list — the two live in the same body and read alike.
See [[adjacent-step-green-signals]].

**Instance 7 — 2026-09-03. A committed script is a proxy for the action it performs.**
Reported the INFRA board's state from the repo's own records: the scripts existed, were
committed, and commit `c8db76d` is titled *"record 2026-09-02 on the INFRA board: three
comments, one new ticket"*. The board had none of it — both scripts had only ever been run
dry. INFRA-1674's last comment was 08-31, and Jira held no record that RisingWave was live
on prod. The commit message asserts the write; only the board witnesses it.

**How to apply:** a script, a commit, a commit message and a `wip/` write-up are all proxies
for a side effect on a remote system. Read the remote. For Jira that is one read-only
command (`scripts/list-open-tickets.py`, `check-sprint-membership.py`), and it is what
separates "we filed that ticket" from "we drafted that ticket".

**Instance 8 — 2026-09-08. Three of them in one script, and the control found all three.**
`scripts/triage-user-cluster-access.sh` was written to tell a NETWORK failure from an ACCESS
one for Tim. Run on Doke's WSL box — a machine already known to reach the cluster — it was
wrong three times:

| Proxy it measured | Verdict it gave | The property |
|---|---|---|
| the egress **interface name** (`eth0`, not `utun*`) | "ROUTING problem, credentials cannot fix it" | whether the port opens — it did, 3 sections later, plus HTTP 200 from two dashboards |
| **one** missing DNS record | "corporate DNS is not answering" | a control lookup — the resolver was fine, `rw2-pg` simply does not exist |
| `kubectl config` at the **default path** | "no contexts at all on this machine" | this team keeps one kubeconfig **per cluster** (`op-usxpress-prod-breakglass.yaml`), by design, so `~/.kube/config` is empty and proves nothing |

The interface one is the worst shape: an **inference contradicted the direct measurement
printed 15 lines below it**, and because outcomes were pooled into a single `NETFAIL` flag,
it also suppressed the credential section — the one part being asked for. In WSL2 (and any
container or NAT'd VM) all traffic leaves via the virtual interface and the host applies the
VPN, so the tunnel is invisible from inside; the check had no valid reading there at all.

**How to apply — this is a procedure change, not just another instance.**

1. **Run a new diagnostic against a machine whose answer you already know**, before sending
   it to the person with the problem. The control is what exposes the proxies; reading the
   script did not, and three rounds of review did not.
2. **Order the checks so measurement precedes inference.** Probe the thing; interpret the
   environment afterwards, and only to *explain* a failure that was independently observed.
   Never let an inferred cause set an outcome flag.
3. **Keep outcomes per-subject.** One pooled failure flag lets an irrelevant finding
   (a missing record for an endpoint nobody asked about) withhold the useful section.
4. **A check must know where it does not apply** — WSL2, containers, NAT — and withdraw,
   rather than answering confidently from a reading that cannot mean anything there.

Related: [[transport-failure-not-a-verdict]], [[adjacent-step-green-signals]].
