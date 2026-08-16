# Interview cheat sheet — one page

Answers, commands and the single discriminator for each exercise. **Interviewer-only.**

Paths assume the candidate repo at `/workspaces/interview-senior-platform` and this repo at
`/workspaces/interview-private`.

---

## Ex 01 — Go spec guard (25 min)

**Answer:** `configVars` is a free-form `map[string]string` the platform copies verbatim. Reject a
value when the **key** names something the platform owns AND the **value** looks like a generated
identity. Both conditions, not one.

**Discriminator:** `VITE_AUTH_TENANT_ID` must still pass. It's a GUID, but a tenant is constant for
the org and doesn't change when a registration is recreated. Flagging it = wrote a regex. Sparing it
with a reason = understood the outage.

```bash
# open it by showing the failure (your screen only - steps 5-7 are Ex02's answer)
cd /workspaces/interview-senior-platform/exercises/01-go-spec-guard
/workspaces/interview-private/recreate.sh "$PWD/hack/ui-spec.yaml"

# the bug, intact
go test ./... && go run . hack/ui-spec.yaml ; echo "exit=$?"      # exit=0

# model answer
awk -f /workspaces/interview-private/fix.awk internal/spec/spec.go > /tmp/s.go && mv /tmp/s.go internal/spec/spec.go
go test ./... && go run . hack/ui-spec.yaml ; echo "exit=$?"      # exit=1, 2 keys, TENANT spared

# reset
git checkout internal/spec/spec.go internal/spec/spec_test.go
```

Also watch: keeps `errors.Join` / appends to `problems` rather than returning early; compiles the
regex once at package level; sorts map keys (Go randomises iteration - flaky tests otherwise).

---

## Ex 02 — auth outage (20 min)

**Answer:** `orders-api`'s registration was destroyed and recreated overnight. Its client ID changed.
Six consumers have the old GUID baked in at *their* deploy time and fail at token acquisition.

**Discriminator:** understanding why redeploying `orders-api` can't help — its own config was never
wrong, the stale values are in the callers. Each redeploy minted another ID and widened the gap.

```bash
cd /workspaces/interview-senior-platform/exercises/02-auth-outage/evidence

# two files, compared, answer it outright
awk '{print $NF}' 02-consumers.txt | grep -oE '^[0-9a-f-]{36}' | sort -u > /tmp/ref.txt
grep -oE '^[0-9a-f-]{36}' 03-current-client-ids.txt | sort -u > /tmp/live.txt
comm -23 /tmp/ref.txt /tmp/live.txt          # -> 1a2b3c4d-...-000000000001

# the mechanism: created == changed, hours ago
awk 'NF && $1 !~ /^#/ {split($2,c,"T"); split($3,l,"T"); if (c[1]==l[1]) print}' 04-secret-timestamps.txt

# the caller kubectl can't fix
jq -r 'select((.downstream_remote_address|startswith("172.24"))|not)
       | "\(.downstream_remote_address)  \(.user_agent)"' 05-istio-access-log-sample.json
```

Offer the log line at 5 minutes if missed: `10.40.7.212  legacy-tms/3.2` - on-prem, blast radius
bigger than the cluster. Fixes: full release of each consumer, sequenced **leaves-first**; or restore
from soft-delete and name the IaC drift. Red flag: "restart the pods".

---

## Ex 03 — stuck rollout (20 min)

**Answer:** the new pod template consumes `sbx-missions-api-m-u` via `envFrom`; that ConfigMap
doesn't exist; `envFrom` resolves at container start so the pod never starts; Helm waits forever.

**Discriminator:** *is the service up?* It is - but the Running pods use the same ConfigMap, so
they're one eviction from unrecoverable. Saying that unprompted is the senior signal.

```bash
kubectl config current-context                        # k3d-sandbox, every time
cd /workspaces/interview-senior-platform/exercises/03-k8s-envfrom-deadlock

kubectl -n sbx-missions get pods                      # 2 Running, 1 CreateContainerConfigError
POD=$(kubectl -n sbx-missions get pods --field-selector=status.phase!=Running -o name | head -1)
kubectl -n sbx-missions describe "$POD" | tail -20    # configmap "...-m-u" not found
kubectl -n sbx-missions get rs                        # old 2/2, new 0/1
kubectl -n sbx-missions get cm                        # only ...-chart exists

# values live ONLY in state/ - jq or grep, either is fine
grep -oE '"DATASTORE__[A-Z_]+": "[^"]*"' state/common-datastore.tfstate.json

# recover (jq route - can't typo)
jq '[.resources[] | select(.type=="kubernetes_config_map_v1") | .instances[].attributes][0]
   | {apiVersion:"v1", kind:"ConfigMap",
      metadata:{name:.metadata[0].name, namespace:.metadata[0].namespace, labels:.metadata[0].labels},
      data:.data}' state/common-datastore.tfstate.json | kubectl apply -f -

kubectl -n sbx-missions rollout status deploy/sbx-missions-api --timeout=120s   # 2 pods Running

# reset
kubectl -n sbx-missions delete cm sbx-missions-api-m-u
kubectl -n sbx-missions rollout restart deploy/sbx-missions-api
sleep 30 && kubectl -n sbx-missions get pods
```

Solved = **2** pods (replicas: 2). Three pods is the stuck state. Worst answer: inventing plausible
ConfigMap content - missing fails loudly, wrong fails silently.

---

## Ex 04 — is it healthy (15 min)

**Answer:** the app caught its own exception, logged it, and returned **HTTP 200**. Request
succeeded, work didn't. Legs silently not created.

**Discriminator:** saying the metrics are **accurate but answering a different question** ("did the
request complete", not "did the work happen"). "The metrics are wrong" is the weak answer.

```bash
cd /workspaces/interview-senior-platform/exercises/04-is-it-healthy/evidence
grep -n -B3 -A12 'ERR' 04-app-log-sample.txt
```

Line 6 announces intent, 7-12 throws `NullReferenceException` at `LegService.cs:1209`, 13 reports
success internally, 14 returns `200`. Order numbers `8814402` / `8814571` are the remediation list.

Evidence-only - **say so when handing it over**, or they'll debug a `kubectl logs` selector for two
minutes. The analyst's test order is the most reliable evidence in the folder: it measures outcome.

---

## Ex 05 — identity design (15 min, discussion)

**Answer:** none required. It's a design conversation.

**Discriminator:** *a browser can't hold a **secret**, but a client ID isn't a secret*. It ships in
the page. The problem isn't security, it's that no supply route was ever built. Ask directly at ten
minutes if it hasn't surfaced.

Ask every candidate: *"a team says 'we need to pin our client ID, we have a reason' - do you let
them?"* Listening for: do they ask what the reason is first; do they separate make-it-impossible from
make-it-obvious; is the exception visible, owned and dated. Absolutes are the weak answer either way.

---

## Environment quick reference

```bash
# candidate-ready check
cd /workspaces/interview-senior-platform && git status --short          # empty
cd exercises/01-go-spec-guard && go run . hack/ui-spec.yaml; echo $?    # exit=0
kubectl -n sbx-missions get pods                                        # 2 Running, 1 failing

# cluster gone after a rebuild
k3d kubeconfig merge sandbox --kubeconfig-merge-default --kubeconfig-switch-context
bash .devcontainer/post-create.sh

# Ex03 fault didn't apply
kubectl -n sbx-missions patch deploy sbx-missions-api --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/envFrom/-",
   "value":{"configMapRef":{"name":"sbx-missions-api-m-u"}}}]'
```

**Timings:** 0-5 greet, 5-15 verbal probes (all five, in order), 15-40 Ex01, 40-58 Ex02 or 03,
58-70 Ex04, 70-75 their questions. Ex05 is the reserve.
