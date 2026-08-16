# Interviewer Guide — Senior Platform Engineer (2026-08)

**Interviewer-only. Never publish this file to the candidate repo.** It lives in the private
companion repo for exactly that reason: it was previously shipped inside the candidate repo, hidden
only by a `files.exclude` setting, which any candidate defeats with a single `cat`.

Built for the backfill round. It deliberately closes the three gaps identified in
`wip/hiring/vibin-backfill-screen-review.md`:

1. **Nobody demonstrated Golang** → Exercise 01 tests it directly, first, while they're fresh.
2. **Nobody was asked about on-prem/bare-metal** → fixed verbal probe below, asked of everyone.
3. **The screens weren't consistent** → the probe set is fixed. Ask all of them, in order, of every
   candidate, or the scorecard isn't comparable.

Every exercise is a real incident from July–August 2026, anonymised. That is the point: it tests
reading evidence, forming and discarding hypotheses, and knowing when a measurement is lying —
which is most of this job.

---

## Before the interview

1. **Spin up your own codespace 15 minutes early** and leave it running. If theirs fails you can
   share yours and lose two minutes instead of the round.
2. Verify:
   ```bash
   kubectl get nodes                              # 2 Ready
   kubectl -n sbx-missions get pods                   # 2 Running, 1 CreateContainerConfigError
   cd exercises/01-go-spec-guard && go test ./... # ok
   go run . hack/ui-spec.yaml                     # exits 0 — this is the bug they must catch
   ```
3. Decide your Copilot policy **before** they join, and tell them. Allowing it is realistic and you
   learn whether they can supervise a suggestion. Disallowing it tests raw ability. Either is fine;
   changing your mind mid-interview is not.

## Time budget (75 minutes)

| Min | Section |
|---|---|
| 0–5 | Greet, confirm they can run things, open `README.md` |
| 5–15 | **Fixed verbal probes** (below) |
| 15–40 | **Exercise 01 — Go.** Make-or-break |
| 40–58 | Exercise 02 or 03 — pick by their background |
| 58–70 | Exercise 04 — short, high signal |
| 70–75 | Their questions, wrap |

Exercise 05 is the reserve: use it if they're strong and fast, or if the environment breaks and you
need something that requires no tooling.

**Choosing between 02 and 03:** if they came in strong on cloud/IAM, give them 03 (Kubernetes
recovery). If they came in strong on Kubernetes, give them 02 (auth outage). Play against their
comfort zone — anyone can perform in their own.

---

## Fixed verbal probes — ask all five, in order

Keep to ~2 minutes each. Write the answers down verbatim where you can.

**1. "Tell me about a platform component you built that other engineers used. What was it, how many
people used it, and how did they get it?"**
*Listening for:* a name, a number, and a distribution mechanism. "How did they get it" is the
question that separates real internal tools from scripts — packaging is where most claims collapse.

**2. "What's the most recent thing you wrote in Go? Walk me through what it did."**
*Listening for:* anything concrete. This is a Go-heavy role and the last round produced zero
evidence of it across four candidates. If the answer is thin, say so in your notes rather than
hoping Exercise 01 will settle it — it partly will, but this tells you whether they *chose* Go.

**3. "Have you run Kubernetes outside a managed service — bare metal, VMs, on-prem? What was
different?"**
*Listening for:* whether they distinguish hybrid from multi-cloud. Many candidates hear "hybrid
cloud" and answer "AWS and GCP". Our hard problems are on-prem clusters alongside EKS. A candidate
who has only ever had a managed control plane isn't disqualified, but they should know what they
haven't done.

**4. "Tell me about a production incident where your first theory was wrong. How did you find out?"**
*Listening for:* a real reversal. Everyone has one. A candidate who can't produce one is either
inexperienced or not reflective, and both matter. Follow up with: *what would have told you sooner?*

**5. "When have you decided not to build something?"**
*Listening for:* judgement about scope and maintenance. Platform teams fail by building more than
they can carry.

---

## Exercise 01 — Go (model answer and signals)

### Opening it — run `recreate.sh` on your screen first

There is no failed deploy for the candidate to look at, because in the real incident there wasn't
one: every deploy was green. Rather than let them read that in prose, show it. **In your own
codespace, on the shared screen, ~30 seconds:**

```bash
cd /workspaces/interview-senior-platform/exercises/01-go-spec-guard
/workspaces/interview-senior-platform-private/recreate.sh "$PWD/hack/ui-spec.yaml"
```

Beats to narrate: step 3 (the ConfigMap is a verbatim copy, so the hand-typed value beats the
generated one), step 4 (`exit=0` — the cheapest moment to catch it, and nothing looked), step 5
(nothing in the platform compares those two values), step 7 (two green redeploys, value unchanged).
Then hand over: *"make the platform refuse this manifest."*

**Never run it in the candidate's codespace and never copy it into the candidate repo** — steps 5
to 7 are Exercise 02's answer.

### What the rule should look like

A package-level compiled pattern, and a check across `configVars`:

```go
var guidRE = regexp.MustCompile(
    `^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(/\.default)?$`)

func validateUI(ui *UI) []error {
    var problems []error

    if ui.Type != "spa" {
        problems = append(problems, fmt.Errorf("ui.type: %q is not a supported ui type", ui.Type))
    }

    for _, k := range slices.Sorted(maps.Keys(ui.ConfigVars)) {
        if !looksLikeIdentityKey(k) {
            continue
        }
        if guidRE.MatchString(ui.ConfigVars[k]) {
            problems = append(problems, fmt.Errorf(
                "ui.configVars.%s: application identity must not be hardcoded — "+
                    "remove this key and read the value the platform supplies at runtime", k))
        }
    }
    return problems
}
```

Sorting the keys matters more than it looks: Go map iteration is random, so without it the error
order changes between runs and the tests become flaky. **A candidate who notices that unprompted is
a strong signal.** If they don't, and their test asserts on a joined error string, ask them to run
it a few times.

### Grading the judgement, not the regex

The exercise deliberately has no single correct strictness. Good answers name the trade-off:

- **Key-name matching** (`CLIENT_ID`, `TENANT_ID`, `SCOPES`) is simple and will miss `VITE_APP_ID`.
- **Value-shape matching alone** (any GUID anywhere) will false-positive on feature flags,
  experiment IDs, tenant identifiers for third parties.
- **Best answer:** match on both, and treat the key list as a starting point rather than a
  guarantee. Some candidates propose inverting it — the platform knows which values *it* supplies,
  so reject any manifest key that collides with a platform-supplied name. That's the strongest
  answer and it's the one we'd actually build.

### The two "if you have time" questions

- **`VITE_TASK_API_SCOPES`** — a *different* application's client ID with `/.default` appended. Same
  bug class. The regex above catches it only because of the optional suffix group. Ask what happens
  if the suffix is `/user_impersonation` instead.
- **The value that's genuinely safe** is `VITE_AUTH_TENANT_ID`. A tenant ID is constant for the
  whole organisation — it doesn't change when an app registration is recreated, so hardcoding it is
  harmless. Candidates who spot this without prompting understand the actual failure mode rather
  than pattern-matching on "GUID = bad". **This is the single best discriminator in the exercise.**
  For the exception mechanism, listen for something other than a hardcoded allowlist: an explicit
  opt-out field in the manifest, or provenance-based matching.

### Senior vs mid

| | Senior | Mid | Concerning |
|---|---|---|---|
| Approach | reads existing code, matches its conventions | writes something correct beside it | rewrites `Validate` in their own style |
| Errors | keeps `errors.Join`, adds to `problems` | returns early on first problem | drops the multi-error behaviour silently |
| Tests | table-driven, covers boundary and negative | one happy, one sad | asserts on exact joined string without sorting |
| Message | tells the developer what to do instead | says "invalid value" | no message change |
| Regex | compiled once at package level | compiled inside the loop | string contains / manual parsing |

**Disqualifier:** cannot get a passing test in 25 minutes with the pattern already in front of them.

---

## Exercise 02 — the auth outage (what actually happened)

**Ground truth:** `orders-api`'s app registration was destroyed and recreated overnight by a
"clean" redeploy. Its client ID changed. Every consumer had the old GUID baked in at *their* deploy
time and could not refresh it, so they all failed at token acquisition — before a request was ever
sent.

**The evidence resolves it in two files.** `02-consumers.txt` shows six services pointing at
`1a2b3c4d-…-000000000001`. `03-current-client-ids.txt` does not contain that GUID at all;
`orders-api` is now `9f8e7d6c-…-000000000002`. That comparison alone is the answer.
`04-secret-timestamps.txt` confirms the mechanism: every other application has `Created` in
2024–2025, and `orders-api` has `Created` == `LastChanged` == a few hours ago. `06-token-test.txt`
names it outright — `AADSTS500011`, resource principal not found.

**Why redeploying `orders-api` couldn't work:** its own configuration was never wrong. The stale
values are in the *callers*. Worse, in the real incident each redeploy minted another client ID and
widened the gap — it happened three times before anyone stopped.

**The odd log line** is `10.40.7.212`, user-agent `legacy-tms/3.2`. Every other caller is `172.24.x`
— in-cluster. That one is on-premises, which means its configuration is not in Kubernetes and
cannot be fixed with `kubectl`. A candidate who spots this and immediately says *"then the blast
radius is bigger than the cluster and someone else has to fix that one"* is thinking about the
right things. Most won't spot it; that's fine, offer it at the five-minute mark and see what they
do with it.

**Fixes worth hearing:**
- Full release of each consumer — sequence leaves-first, because each release recreates that
  service's own registration and breaks *its* consumers. Ordering is the senior part of the answer.
- Restore the deleted registration from the identity provider's soft-delete window. Fast, no
  releases, leaves infrastructure-as-code drift that the next deploy undoes. A candidate who
  proposes this *and* names the drift is thinking clearly.

**Prevention:** emit a deterministic identifier (a stable URI) rather than a generated GUID, so
consumers reference something that survives recreation. If they get here on their own, that's the
top of the range.

**Red flag:** "restart the pods". Nothing in the evidence suggests process state, and it reveals
someone reaching for a familiar action rather than reading.

---

## Exercise 03 — the stuck rollout (what actually happened)

**Ground truth:** the deploy tool's Terraform step and its Helm step disagreed about a ConfigMap.
The new pod template consumes `sbx-missions-api-m-u` via `envFrom`; that ConfigMap did not exist; the
new pod could not start; Helm waited for a rollout that could never complete and eventually timed
out.

**The diagnosis path we want:**

```bash
kubectl -n sbx-missions get pods                       # 2 Running (old RS), 1 not starting (new RS)
kubectl -n sbx-missions describe pod <the stuck one>   # Error: configmap "sbx-missions-api-m-u" not found
kubectl -n sbx-missions get rs                         # two ReplicaSets, one scaled up and stuck
kubectl -n sbx-missions get cm                         # sbx-missions-api-chart exists, sbx-missions-api-m-u doesn't
```

**The question that separates candidates** is the second one in the exercise: *is the service up?*
It is — two pods are Running and serving. But they consume the same ConfigMap via `envFrom`, and
`envFrom` is read at container start. So they survive only until something stops them. A node
drain, an eviction, an autoscaler consolidation, and they cannot restart.

A senior candidate says this unprompted and treats it as the reason to hurry. A mid candidate
diagnoses correctly and misses that the healthy pods are load-bearing and fragile.

### Where the values live, and what counts as reading them

The three `DATASTORE__CLUSTER__*` values exist in **exactly one place**: `state/common-datastore.tfstate.json`.
`manifests/deployment.yaml` names the missing ConfigMap in its `envFrom` block but does not contain
its contents. Confirm with:

```bash
grep -rln 'datastore-pl-0\|DATASTORE__CLUSTER' .    # -> state/ only
```

That is the point of the exercise: a candidate who never opens `state/` has nowhere to get the
values but their imagination.

**`jq` is not the test.** Any of these are equally good — grade the *reading*, not the tool:

```bash
jq -r '.resources[] | select(.type=="kubernetes_config_map_v1") | .instances[].attributes.data' state/common-datastore.tfstate.json
grep -oE '"DATASTORE__[A-Z_]+": "[^"]*"' state/common-datastore.tfstate.json
```

...or simply opening the file in the editor. Only be concerned if the values appear without the
candidate having looked anywhere.

### The values, for your reference

| Key | Value |
|---|---|
| `DATASTORE__CLUSTER__SERVER` | `datastore-pl-0.internal.example.net` |
| `DATASTORE__CLUSTER__TLS_CRT_KEY_FILE` | `/etc/certs/tls-combined.pem` |
| `DATASTORE__CLUSTER__CONNECTION_STRING` | `mongodb+srv://datastore-pl-0.internal.example.net/?authSource=%24external&authMechanism=MONGODB-X509&retryWrites=true&w=majority&readPreference=secondaryPreferred&appName=sbx-missions-api` |

Labels on the ConfigMap: `app=sbx-missions-api`,
`platform.example.io/environment=production`, `platform.example.io/project=sbx-missions-api`,
`platform.example.io/revision=0.4.12`.

Two details candidates get wrong from memory: the connection string ends `appName=sbx-missions-api`
(not `missions-api`), and `kubectl create configmap` has no flag for labels, so a kubectl-only
recovery needs a second `kubectl label` command. Dropping the labels is a partial answer - the
platform's record and the cluster still disagree.

**Recovery - the kubectl route**, if the candidate prefers it (equally valid):

```bash
kubectl -n sbx-missions create configmap sbx-missions-api-m-u \
  --from-literal=DATASTORE__CLUSTER__SERVER='datastore-pl-0.internal.example.net' \
  --from-literal=DATASTORE__CLUSTER__TLS_CRT_KEY_FILE='/etc/certs/tls-combined.pem' \
  --from-literal=DATASTORE__CLUSTER__CONNECTION_STRING='mongodb+srv://datastore-pl-0.internal.example.net/?authSource=%24external&authMechanism=MONGODB-X509&retryWrites=true&w=majority&readPreference=secondaryPreferred&appName=sbx-missions-api'

kubectl -n sbx-missions label configmap sbx-missions-api-m-u \
  app=sbx-missions-api \
  platform.example.io/environment=production \
  platform.example.io/project=sbx-missions-api \
  platform.example.io/revision=0.4.12
```

Order matters: `label` before `create` fails with `NotFound`.

**Recovery - the manifest route:** read the ConfigMap's real content from
`state/common-datastore.tfstate.json` and recreate it exactly.

```bash
jq -r '.resources[] | select(.type=="kubernetes_config_map_v1") | .instances[].attributes.data' \
  state/common-datastore.tfstate.json
```

then `kubectl apply` a ConfigMap with that data and those labels. The stuck pod starts within
about thirty seconds, the rollout completes.

**Recovery — the other defensible answer:** `kubectl -n sbx-missions rollout undo deploy/sbx-missions-api`.
That reverts to the pod template without the missing reference. It works, and it is a legitimate
mitigation. Push on it: the intended configuration is now missing, the platform will reapply the
same broken state on the next deploy, and you've bought time rather than fixed anything. A
candidate who proposes it *and* names those costs is reasoning well. One who proposes it as a fix
is not.

**Wrong answers, in descending order of concern:**
- `kubectl delete deployment` and let the platform recreate it — destroys the working pods, turns a
  degraded service into an outage
- Inventing plausible ConfigMap content — the app connects to the wrong datastore and the failure
  is now silent
- Editing the live Deployment to drop the `envFrom` entry — same as `rollout undo` but leaves no
  record
- Scaling to zero "to get a clean start"

**The "if you finish early" answer:** a clean redeploy would have destroyed and recreated the app
registration — the Exercise 02 incident. Whether they connect the two exercises unprompted is worth
noting; it's the same failure viewed from two ends.

---

## Exercise 04 — is it healthy (what actually happened)

**Ground truth:** the application caught its own exception, logged it, and returned HTTP 200. The
request succeeded; the work didn't. Missions silently weren't created.

**The reconciliation:**
- Metrics show 100% 200s because **the service really did return 200**. The metric is accurate. It
  is answering "did the request complete", not "did the work happen".
- Pods are healthy because nothing crashed. Liveness and readiness measure the process, not the
  outcome.
- The application log is the only place the failure appears — and only if you look for `ERR` in a
  stream that is otherwise 200s.
- The operations analyst is the ground truth: no leg was created for a test order, twice.

**The answer we want on the call:** *"Yes, it's still failing. The service is returning 200 while
swallowing the error, so nothing in our monitoring will show it. The only reliable signal right now
is checking whether the work actually happened."* Confident about what's known, explicit about what
isn't.

**Weak answers:** "metrics look clean so we're fine" (didn't read the log). "The metrics are wrong"
(they aren't — this matters, because a candidate who dismisses accurate instrumentation will
dismiss it next time too).

**The harder question** is deliberately open. Good directions: emit a business-outcome metric owned
by the app (legs created per minute) and alert on absence; make the platform's log pipeline
surface unhandled-exception counts regardless of HTTP status; a synthetic transaction. What we want
is specificity plus an answer to "how does this not rot" — usually ownership, or making the signal
something the team already looks at.

---

## Scoring rubric

Score each 1–4. **3 is the hire bar.** Anything below 2 in *Evidence discipline* is a decline
regardless of the rest — it's the core of the job.

| Dimension | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| **Go fluency** | can't produce working code | works, unidiomatic | idiomatic, tested, follows conventions | plus notices map-ordering / compiles regex once / thinks about API shape |
| **Evidence discipline** | theorises before reading | reads, then jumps to first theory | forms a hypothesis and states what would falsify it | actively looks for the evidence that would prove them wrong |
| **Blast radius** | acts destructively without pause | checks before destructive actions | reasons about ordering and dependencies unprompted | identifies the fragile-but-working state others miss |
| **Kubernetes depth** | surface commands only | diagnoses common failures | understands controllers, ReplicaSets, how config reaches a pod | reasons about the reconciliation loop and where two systems disagree |
| **Communication** | silent, or narrates without thinking | explains when asked | thinks out loud usefully | changes register for the audience; can answer a director |
| **Judgement** | absolutes ("always/never") | reasonable defaults | names trade-offs explicitly | knows when to enforce vs enable, and says why |
| **Honesty under pressure** | bluffs | hedges vaguely | says "I don't know, here's what I'd check" | distinguishes what evidence supports from what they're inferring |

### Notes to write while they work

- Exact words when they say "I don't know" — how they follow it is the signal
- Any moment they change their mind, and what caused it
- Anything they check *before* a destructive command
- Whether they asked a clarifying question before starting each exercise

---

## Red flags

- **Confident wrongness that survives contact with evidence.** Being wrong is fine and expected;
  not updating when the terminal disagrees with you is not.
- **Reaching for a familiar action rather than reading** — "restart it", "redeploy it", "delete and
  recreate". Three of tonight's real incidents were made worse by exactly this.
- **Cannot say what would falsify their theory.** Ask directly if it doesn't come up.
- **Treats the exercises as puzzles with hidden answers** and tries to guess what you want rather
  than working the problem.
- **Dismisses accurate instrumentation as broken** because it disagrees with their conclusion.

## Positive signals that are easy to miss

- Asks what a deploy actually *does* in our platform before proposing one
- Notices the healthy pods are fragile in Exercise 03
- Spots that the tenant ID is safe to hardcode in Exercise 01
- Connects Exercise 02 and Exercise 03 as the same failure from two ends
- Asks who owns something, not just what's broken

---

## After the interview

1. **Score within four hours.** Memory fades and generosity grows overnight.
2. Remove the collaborator (see `CANDIDATE-WORKFLOW.md`).
3. Ask them to delete their codespace.
4. Add one line to the scorecard for the round: the thing they did that you'd want on the team, and
   the thing that would worry you on week one.
