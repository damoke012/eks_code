---
name: pr-review-rw
description: Review a PR that touches the on-prem cluster (especially RW namespaces). Runs the protect-RW workflow — identify the target namespace, independently verify against live cluster + source repo, draft Round-N review comment in the BLOCKER/CLEARED/ADVISORY format, document in wip/, update memory. Triggered by `/pr-review-rw <repo> <PR#>` or `review PR #N on <repo>`.
---

# /pr-review-rw

Structured review for PRs that touch on-prem cluster state — especially anything in or near `risingwave` (Tim's) or `risingwave-2` (Doke's) namespaces, or any cluster-wide platform change.

This skill encodes the workflow proven on PR #7 review (2026-05-29) where independent verification caught two findings Idris's reply alone would have missed (orphan ExternalSecret + dead postgres HR).

## When to use

- The user asks to review a specific PR (`/pr-review-rw <repo> <PR#>`, or "review #7 on iaac-talos-flux-cluster").
- The user is about to approve a PR and wants the protect-RW pass first.
- A PR has been updated and a Round-2/3 review is needed.

## When NOT to use

- Pure documentation PRs.
- PRs on repos unrelated to op-usxpress-dev.
- PRs that the user explicitly says don't need protect-RW scrutiny.

## Environment constraint

**Codespace cannot reach the cluster.** All live-cluster verification (kubectl, aws) must run on WSL. This skill presents copy-paste blocks for the user to run there.

## The workflow

### Phase 1 — Read the PR and identify scope

1. Run on WSL: `gh pr view <PR#> --repo <repo> --json title,state,headRefName,baseRefName,headRefOid,mergeable,reviewDecision,commits`.
2. Run on WSL: `gh pr diff <PR#> --repo <repo>` — capture the full diff.
3. Identify what changes, what resources it touches, what cluster state it would affect.

### Phase 2 — Identify the target namespace (Tim coord gate)

The rule (from [[feedback_protect_rw_onprem_workload]]).

⚠️ **This table is about `op-usxpress-dev` only.** It was written 2026-05-29, when dev was the
only on-prem cluster. On 2026-08-20 it read as contradicting the `risingwave-onprem` memory;
neither was stale — both describe dev and neither said so. On **op-qa** and **op-prod** the
`risingwave` namespace is created and reconciled by `iaac-talos-flux-platform`'s own
`risingwave-operator` Kustomization and carries no owner label, so no dev-era coordination gate
applies. Check `kubectl get ns <ns> -o jsonpath='{.metadata.labels}'` for the managing
Kustomization before assuming an owner, and scope every ownership claim to a named cluster.

**`risingwave-2` is dev-only.** It is our own platform work and is never promoted. QA and
prod have `risingwave` and nothing else — confirmed in Secrets Manager 2026-09-01. Any change
that builds a `risingwave-2` path from an environment variable is wrong on its face; map the
namespace per environment, never interpolate it. Do not raise "which namespace should QA use"
as an open question.

| Target ns (op-dev) | Tim coord required? |
|---|---|
| `risingwave` (Tim's) | ✅ Yes |
| `risingwave-2` (Doke's IaC) | ❌ No |
| Cluster-wide / platform with possible RW impact | ✅ Yes |
| Other | Case-by-case |

For Kustomization-based PRs, target ns is determined by the SOURCE repo's manifests, not the Kustomization file. Verify by cloning the source repo + grepping namespace fields:

```bash
gh repo clone <source-repo-org>/<source-repo> /tmp/<source-repo> -- --depth 1 --branch <branch>
grep -E "^\s*namespace:" /tmp/<source-repo>/<path>/*.yaml | sort -u
cat /tmp/<source-repo>/<path>/namespace.yaml
```

**Don't trust the PR author's word on which ns; verify.**

### Phase 3 — Independent verification (TRUST BUT VERIFY)

This is the high-leverage step. Don't accept the PR author's claims; check the live cluster yourself.

For each claim made by the PR or its description, generate a verification command and run it. Standard battery:

```bash
# Baseline — RW Running?
kubectl get rw -A
kubectl get pods -n <target-ns> -o wide

# What does live state actually show?
kubectl -n <target-ns> get <resource> -o jsonpath='{...}'

# Is the bucket/secret/secret-ref/version the PR patches against actually what's running?
# Construct comparison: live value vs PR patch value

# Recent activity — has the author already pre-applied?
kubectl get events -n <target-ns> --sort-by=.lastTimestamp | tail -30
```

For source-repo manifests, also verify against the cloned source — does the CR / HR / config the PR patches actually exist with the field paths assumed by the patches?

### Phase 3b — The hostname gate (any PR touching a VirtualService or Gateway)

Three failures live here, all silent, all shipped in the last five weeks. Run this gate
whenever the diff touches `hosts:`, a `gateways:` reference, an `external-dns.alpha…`
annotation, or `risingwave-routes/kustomization.yaml`.

**1. A hostname is not one application.** A VirtualService with no `uri` match is a
catch-all, so repointing the host relocates *every* path under it — including OIDC issuer
and callback endpoints that clients hardcode. PR #166 moved `/dex` and `/auth` along with
`/` and 404'd "Sign in with SSO"; #167 reverted it within the hour. The route looked
correct and `/` returned 200 throughout.

```bash
# every declared path on the host (no 'uri:' lines means it carries ALL of them)
kubectl --context admin@op-usxpress-<env> -n <ns> \
  get virtualservices.networking.istio.io -o yaml | grep -nE 'hosts:|uri:|prefix:|host:'

# the CONSUMERS -- an issuer URL lives in the app's config, not in the routing
kubectl --context admin@op-usxpress-<env> -n <ns> \
  get deploy,cm -o yaml | grep -iE 'issuer|redirect|callback|_url'
```

A repoint is **BLOCKER** until the second grep is empty, or until the issuer, the callback
and the identity provider's redirect URI move first — and the Entra app registration is
shared across dev/QA/prod, so that is an *addition*, never a replacement.

**2. Ask the registry, not the resolver.** The `usxpress.io` SOA minimum is **86400**, so a
negative answer is cached for 24 hours. Resolving a hostname to find out whether its record
exists is what *makes* it not exist — and checking first is the natural move, so this trap
fires on the careful reviewer. It minted three of op-dev's five RisingWave hostnames.

Read Route 53, then resolve only confirmed names: `bash scripts/onprem-dns-finish.sh <env>`.
It is read-only and it cannot commit this error. If you need one name by hand, use
`dig +short <name> @8.8.8.8` (public, not the corporate recursive) and prove the route with
`curl --resolve <host>:443:<node-ip>`, which needs no DNS at all.

**3. A deleted route file freezes the whole directory.**
`infrastructure/risingwave-routes/kustomization.yaml` **enumerates** its resources. Removing
a file while its line stays fails the kustomize build, so *every* route in the directory
stops reconciling and holds its last-applied state. The Kustomization reports the error; no
hostname reports anything.

```bash
kustomize build infrastructure/risingwave-routes/ \
  && echo BUILD OK || echo "BLOCKER -- directory will stop applying"
```

Pair that with a count: `grep -c 'kind: VirtualService'` before and after must differ by
exactly the number of routes the PR claims to remove, and every keeper must still appear in
the render.

**4. A resolving name is not a bound listener.** `rw-sql.op-prod` and `rw-postgres.op-prod`
resolved to prod's nodes for weeks with nothing bound to 4567 — prod had `shared-http` but
no `tcp-passthrough` until platform #143. A VirtualService naming an absent Gateway serves
nothing, with no error, no status condition and no event.

```bash
kubectl --context admin@op-usxpress-<env> -n istio-ingress \
  get gateways.networking.istio.io \
  -o custom-columns='NAME:.metadata.name,PORTS:.spec.servers[*].port.number'
```

Query `gateways.networking.istio.io`, never `gateway` — the bare kind resolves to the
Gateway API CRD and returns zero rows while Istio Gateways exist.

**Targets are per cluster.** A record must point at **this** cluster's own nodes: dev 7,
QA 3 (platform only), prod 10. external-dns skips a record another `--txt-owner-id` holds,
so a copied VirtualService produces exactly nothing, visibly. Mirror the cluster's own
working route, never another cluster's.

### Phase 3c — The secrets gate (any PR touching an ExternalSecret, `000-secrets.rw`, or a credential path)

Four failures live here. Every one reported green or absent, and three of them cost weeks.

**1. ESO writes a PARTIAL Secret.** A missing property does not block the others.
`SecretSyncedError` is set, the Secret looks populated, and the pod dies at **container
creation** with `RESTARTS 0` — invisible to restart alerts. QA sat wedged seven days this
way on `entity-postgres`, which had never been created at all.

```bash
# COUNT the keys. The condition is not the check.
kubectl --context admin@op-usxpress-<env> -n <ns> get secret <name> \
  -o jsonpath='{range $k,$v := .data}{$k}{"\n"}{end}' | sort | nl
# how many did the manifest ask for?
grep -c 'secretKey:' <path>/externalsecret.yaml
```

The two numbers must match. A mismatch is a **BLOCKER**, whatever the condition says.

**2. An empty string reads as configured.** QA's three `schema_registry_*` properties
existed and were empty for weeks; `CREATE SECRET` made empty secrets and the failure
surfaced at Avro decode time, nowhere near the cause. Check lengths, never values:

```bash
aws secretsmanager get-secret-value --profile <env-profile> \
  --secret-id op-usxpress-<env>/risingwave/kafka --query SecretString --output text \
  | python3 -c 'import json,sys; [print(f"{k:42} {len(v)}") for k,v in sorted(json.load(sys.stdin).items())]'
```

Any `0` is a BLOCKER. This prints lengths only — never the value.

**3. A placeholder that satisfies the validator is worse than a blank.**
`KAFKA_SCHEMA_REGISTRY_MESSAGE: unknown` passes `apply.sh`'s non-empty check and then fails
inside RisingWave; `console_license_key` held `PLACEHOLDER_INJECT_REAL_LICENSE` while its
ExternalSecret reported `SecretSynced=True` in four minutes. Grep the diff for
`unknown`, `PLACEHOLDER`, `TBD`, `changeme`, `xxx` — and assert the *shape* the consumer
needs (a licence is a compact JWT: three dot-separated parts, `eyJ` prefix).

**4. Property casing differs between environments.** Dev's keys are `KAFKA__…`, QA's are
`kafka__…`. Code that reads one casing gets **nothing** from the other, silently. Any PR that
copies a credential path to a new environment must be checked against that account's actual
key names, not against the sibling's.

**Two more that are not about the diff:**

- **`secret_store_private_key` is load-bearing.** It decrypts every `backend='meta'` secret.
  If a Terraform run regenerates it, all twelve `kafka_*` secrets become unreadable and the
  symptom presents as bad Kafka credentials. Confirm `ignore_changes` before approving
  anything that touches `secrets.tf`.
- **A value change does not reach a running pod.** `secretKeyRef` resolves at pod creation, so
  the pod must be **deleted**, not restarted. For flow-C secrets, re-run the workflow and
  re-list: `SELECT name FROM rw_catalog.rw_secrets;` — 12 rows, listed, not inferred from an
  exit code.

### Phase 3d — Ask the admission webhook, for anything it validates

A PR can be correct in every respect you checked and still be **rejected by an admission
webhook**, and a rejected dry-run fails the WHOLE Kustomization — freezing every other
resource in that directory while the PR shows merged and green.

`iaac-talos-flux-platform#158` (2026-10-12) added a PrometheusRule whose expressions do not
parse. It froze dev's `prometheus` Kustomization and, through `dependsOn`, `grafana`. Six CI
checks passed. I had verified the `ruleSelector` label matched, the Argo controller's kind and
name, that all five suppressed alertnames existed, and the route ordering — and never asked
whether the PromQL was valid. The reviewer's checklist item about dry-run failures freezing a
Kustomization was already in this skill; I did not run it.

**One command settles it**, and it is the same for PrometheusRules, ValidatingWebhook-guarded
CRs, Istio resources, Kyverno-gated workloads and anything else with a webhook:

```
gh repo clone <org>/<repo> /tmp/pr --depth 1 --branch <base>
kubectl --kubeconfig=<kc> apply --dry-run=server -f /tmp/pr/<changed file>
```

Server-side, not client-side: `--dry-run=client` never reaches the webhook. A connection
timeout (`dial tcp …: i/o timeout`) is NOT MEASURED, not a pass.

**The PromQL trap specifically:** a parenthesised expression immediately after `group_left` is
parsed as its **label list**, so

```
a{...} * on (ns, pod) group_left
(b{...} == 1)
```

fails with `unexpected "{" in grouping opts`. It needs `group_left()`. Note the same keyword
followed by `max by (...)` parses fine — only a leading `(` collides. So fix the occurrence the
webhook names, not every occurrence of the keyword.

### Phase 4 — Build the findings table

| # | Item | State | Severity | Notes |
|---|---|---|---|---|
| 1 | <description> | OPEN / CLEARED / FIXED | BLOCKER / Advisory / Lint | <evidence> |

Mark CLEARED only when independently verified (not just "PR author says it's fine").
Mark BLOCKER only for items that affect correctness, data, or trust boundaries.

### Phase 5 — Draft Round-N comment

Use this structure:

```
Round N — <commit-sha> verified.

**Cleared ✅**
- <item> — <one-line evidence>
- ...

**Still open**
1. (BLOCKER) <item> — <description + ask>
2. (BLOCKER) <item> — <description + ask>
3. (advisory) <item> — <description + suggested follow-up>

**Coordination ask — before you merge, please confirm:**
- <branch-test confirmation>
- <Tim coord> (if ns = risingwave)
```

Save the body to a temp file on WSL, then `gh pr comment <PR#> --repo <repo> --body-file <tmpfile>` (heredocs with backticks tend to mis-terminate; --body-file is safer).

### Phase 6 — Document in wip/

Create or update:
- `wip/<initiative>/STATE.md` — current decision + blockers
- `wip/<initiative>/pr-<N>-review-<date>.md` — full audit trail (one file per PR, Round-N sections appended)

The wip doc is the source of truth across compactions — memory holds the summary + pointer.

### Phase 7 — Update memory

- One memory file per PR review (e.g., `prN_<short-name>_review_<date>.md`).
- Add a one-line index entry in `MEMORY.md` near the most-related anchor.

### Phase 8 — On approval

When all blockers clear + coord met:
- `gh pr review <PR#> --repo <repo> --approve --body "<approval message>"`
- Commit STATE.md update with "APPROVED" status.
- Suggest filing any advisory items as Idris-task tickets (`/idris-task`).
- Post-merge, update [[rw-manifest-landscape-2026-05-28]] (or equivalent reference memory) with the new cluster state.

## Reusable verification helpers

Two scripts live under `scripts/` to speed up Phase 3:

- `scripts/verify-rw-baseline.sh` — runs the standard RW health checks (CR status, pod ages, postgres wiring, stateStore, bucket). Paste-into-WSL block.
- `scripts/pr-touches-ns.sh <source-repo-url> <branch> <manifests-path>` — clones the source repo, prints every distinct namespace it manages. Used in Phase 2.

## Quality bar checklist (run mentally before posting Round 1)

- [ ] I confirmed the target namespace from the SOURCE manifests, not the PR description.
- [ ] For every numeric/string value in a patch, I have a kubectl command that confirms it matches live.
- [ ] For every Secret/ConfigMap reference, I traced it back to an ExternalSecret or source manifest and confirmed it's actually consumed somewhere.
- [ ] For every HelmRelease change, I checked the live release name + version.
- [ ] For JSON patch ops (`add` to `env/-`, `replace` to specific paths), I checked the source for whether the path / array currently exists.
- [ ] I gave Idris (or whoever) a concrete `kubectl` line to confirm — not just "please verify yourself."
- [ ] **For every workload with a listener: does the readiness probe target the port that
      carries traffic?** A probe on a sidecar/admin/status port proves nothing about the data
      port. INFRA-1654: `ghostunnel-rw-postgres` ran `--listen=:4567` behind a Service that is
      `5432 -> targetPort 5432`, with `readinessProbe.tcpSocket.port: status` (9090). Both pods
      reported `READY true, 0 restarts` while serving nothing, on dev **and** QA, for eleven
      weeks. Check with `scripts/check-service-ports-listening.sh <ns> --context <ctx>`.
- [ ] **Did I read the DELETED lines, especially deleted comments?** A comment being
      removed often contains the argument against the change removing it. `iaac-talos#62`
      (2026-09-09) widened a GHA OIDC trust subject to `repo:ORG/REPO:*` and added Tim's
      production secret path to the same role — and deleted the two comments saying
      *"Blocks PRs from forks + other branches … rather than broadening this scope"* and
      *"Kept as separate roles so prod and CICD-env credentials are independently
      rotatable … Does NOT include /risingwave/ (Tim's prod)."* Quoting the author's own
      prior reasoning back is stronger than arguing it yourself, and it is free — it is
      already in the diff, on the `-` side. Then **verify the deleted claim still holds**
      before relying on it: `gh api repos/ORG/REPO/contents/<dir> --jq '.[].name'`
      confirmed the companion role still existed, which turned a tidy-up into a live
      regression.
- [ ] **Did I read the WHOLE diff, including hunks I did not intend?** A PR assembled by
      copying a file wholesale carries every difference between the two copies, not just the
      change you meant. `iaac-talos-flux-platform#100` was a Kyverno change that also reverted
      an ApplicationSet's `repoURL` from `ssh://` to `https://` and took delivery down for 18
      hours. Check with `scripts/check-argocd-repo-credentials.sh` after any argocd-apps or
      argocd-config change.
- [ ] **After a merge, did the revision actually move?** Each on-prem cluster has two
      GitRepositories: `flux-system` (the cluster repo, `master`) and `infra` (the platform
      repo, branch `op-<env>`). Every `infrastructure/*` Kustomization uses `infra`.
      Reconciling `flux-system` leaves them on the cached revision and still prints
      `✔ applied revision …<old sha>`. Use
      `flux reconcile kustomization <name> --with-source` and confirm the sha changed.
- [ ] **Did I measure the property, or something adjacent to it?** Four confident wrong
      answers this year came from a proxy: a `%VAR%` count standing in for "is this
      parameterised", resource **tags** standing in for "did Terraform build this"
      (they do not — the provider sets no `default_tags`; creation date and the IAM
      policy's `Resource` list settle it), `git grep` without `-P` standing in for
      "are there unguarded DROPs", and `kubectl get gateway` standing in for "does this
      cluster have Istio Gateways". Every one returned a clean result and answered a
      different question. Name the direct evidence before reporting the property.
- [ ] **Did I treat a zero as a diagnosis?** A materialized view reading 0 rows has at least
      four indistinguishable causes: still backfilling, a topic retaining no messages, a
      consumer group that is not authorised, and a failing Avro decode. On 2026-09-11 QA's
      `mv_brand` was 0 for **two** of them at once — `GroupAuthorizationFailed` in the compute
      log, and a topic at `low: 194, high: 194`. Neither is visible from the count, and one of
      them is not a defect. Worse, `SELECT * FROM <source> LIMIT 1` came back **clean**,
      because a batch scan uses no consumer group and so cannot fail the way the streaming
      path was failing — a green check that shares none of the defect it appears to test.
      Run `scripts/rw-diagnose-empty-mv.sh <env> <mv> <source>`, which reads the compute log
      and names which cause applies. Never report "the pipeline works" from a row count alone,
      and never report "it is broken" without saying which of the four.

- [ ] **Did the resource kind I queried actually resolve?** `kubectl get gateway` hits the
      **Gateway API** CRD and returns zero rows while `gateways.networking.istio.io` has
      several. Zero rows from the wrong kind is not absence. Fully qualify the kind
      whenever a short name could be ambiguous.
- [ ] **Before raising an external request, did I check whether another environment already
      solved it?** RisingWave's prod Entra "app registration request" evaporated on
      2026-08-31 once dev and QA turned out to share one registration — prod was a redirect
      URI and a copied secret. Grep the sibling clusters' manifests first.
- [ ] **Can this change apply to the object that ALREADY EXISTS?** Reviewing whether a change
      is *correct* is a different question from whether it can *land*. Server-side apply keeps
      a field the manifest stops mentioning, so a change to a mutually-exclusive field is
      rejected forever on a live object while being perfectly valid on a fresh one.
      `iaac-risingwave-onprem#36` (2026-09-15) switched the QA console to `strategy: Recreate`;
      the live Deployment still carried the `rollingUpdate` block Kubernetes defaulted onto it,
      and `spec.strategy.rollingUpdate: Forbidden: may not be specified when strategy type is
      'Recreate'` failed the dry-run on every reconcile for ~4 hours. **A dry-run failure fails
      the WHOLE Kustomization**, so every other resource in it froze too, and the PR looked
      merged and done. Two review rounds asked *why* `Recreate` and never asked *whether it
      could apply*. The field families to check: `strategy.type` vs `strategy.rollingUpdate`,
      `spec.selector` and other immutable fields, `clusterIP`, `serviceName`, a Job's
      `template`, a PVC's `resources.requests.storage` shrinking. Confirm with the live object
      before approving:
      `kubectl --context <ctx> -n <ns> get <kind> <name> -o jsonpath='{.spec.strategy}{"\n"}'`
      and after the merge confirm the **pod** moved, not that the Kustomization says Ready.
- [ ] **Do the container's listen flags agree with the Service's `targetPort`?** A numeric
      `targetPort` needs no matching `containerPort`, so Kubernetes will not complain about a
      Service that points at a port nothing binds.

## Anti-patterns to avoid

- **Approving on the PR author's word alone.** Independent verification caught 2 of 6 blockers on PR #7 that wouldn't have surfaced otherwise.
- **Trusting the diff hunk for whole-file state.** Diffs show changes only; for "did you fix the lint at line 5" type questions, read the full file.
- **Treating Tim coord as optional.** When ns = `risingwave`, it's mandatory ([[feedback_protect_rw_onprem_workload]]).
- **Mixing "code clears" with "coord clears".** Approval needs both gates clear; document them separately.
- **Round-1 comment that's a vague "looks risky."** Be specific: cite the exact line, name the exact mode of failure, give the exact verification command.

## Output

- Posted PR comment (Round N).
- Updated `wip/<initiative>/STATE.md` + review doc.
- Updated `memory/<initiative>_pr_review_<date>.md` + `MEMORY.md` index entry.
- On approve: optional Idris-task ticket drafts for follow-up advisories.

## Apply

- This skill is invoked when a user asks for a PR review on an on-prem-cluster-touching PR.
- Run all live-cluster commands on WSL; codespace can only reach GitHub.
- Always lean on `/idris-task` for advisory follow-up tickets, not inline scope-creep on the current PR.
