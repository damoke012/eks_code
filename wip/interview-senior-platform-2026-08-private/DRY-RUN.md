# Dry run — step by step

Follow this once, start to finish, before you use the environment with a candidate.
Every step says what to run and what you should see. If a step doesn't match, stop there.

Repo: https://github.com/dare-x/interview-senior-platform (private)

---

## PART A — get the environment up

### Step 1. Create the codespace
Browser → the repo → **Code → Codespaces → Create codespace on main**. Wait ~3 minutes.

### Step 2. Confirm you are NOT on a real cluster
```bash
kubectl config current-context
```
**Expect:** `k3d-sandbox`
**If it shows an EKS ARN, stop.** You are in the wrong terminal.

### Step 3. Confirm the environment built
```bash
go version
kubectl get nodes
kubectl -n sbx-missions get pods
terraform version
jq --version
```
**Expect:** go1.24+, 2 nodes Ready, 3 pods (2 Running, 1 CreateContainerConfigError), tf 1.10.x, jq 1.7+

### Step 4. Confirm Exercise 01's bug is intact
```bash
cd exercises/01-go-spec-guard
go test ./...
go run . hack/ui-spec.yaml ; echo "exit=$?"
```
**Expect:** tests ok, and `exit=0`.
`exit=0` is correct — the manifest with the hardcoded client ID currently passes. That is the bug.

---

## PART B — Exercise 01 (Go)

### Step 5. Read what they read
```bash
cat EXERCISE.md
cat hack/ui-spec.yaml
sed -n '90,110p' internal/spec/spec.go
```
The `TODO(exercise)` line in `validateUI` is where the work goes.

### Step 6. Apply the model solution
```bash
cp ~/eks_code/wip/interview-senior-platform-2026-08-private/ex01-solved/spec.go internal/spec/spec.go
cp ~/eks_code/wip/interview-senior-platform-2026-08-private/ex01-solved/spec_test.go internal/spec/spec_test.go
```
(In the codespace you won't have `~/eks_code`. Either paste from the interviewer guide, or read
the solution from this file on WSL and type it in — the point is to see it work once.)

### Step 7. Prove it works
```bash
go test ./...
go run . hack/ui-spec.yaml ; echo "exit=$?"
go run . hack/sample-spec.yaml
```
**Expect:**
- tests pass (4 original + 7 new table cases)
- `ui-spec.yaml` now exits 1, flagging `VITE_AUTH_CLIENT_ID` and `VITE_TASK_API_SCOPES`
- `VITE_AUTH_TENANT_ID` is NOT flagged  ← the discriminator
- `sample-spec.yaml` still valid

### Step 8. Reset for the candidate
```bash
git checkout internal/spec/spec.go internal/spec/spec_test.go
go run . hack/ui-spec.yaml ; echo "exit=$?"   # back to exit=0
```

---

## PART C — Exercise 02 (auth outage)

### Step 9. Look at what they get
```bash
cd ../02-auth-outage/evidence
ls -1
cat 01-report.md
```

### Step 10. The comparison that solves it
```bash
awk '{print $NF}' 02-consumers.txt | grep -oE '^[0-9a-f-]{36}' | sort -u > /tmp/ref.txt
grep -oE '^[0-9a-f-]{36}' 03-current-client-ids.txt | sort -u > /tmp/live.txt
comm -23 /tmp/ref.txt /tmp/live.txt
```
**Expect:** `1a2b3c4d-0000-4aaa-8bbb-000000000001`
Six consumers point at an identity nothing is running.

### Step 11. Which app was rebuilt
```bash
awk 'NF && $1 !~ /^#/ {split($2,c,"T"); split($3,l,"T"); if (c[1]==l[1]) print}' 04-secret-timestamps.txt
```
**Expect:** `app-prod-orders-api  2026-08-13T02:07:11Z  2026-08-13T02:07:19Z`
Created and last-changed 8 seconds apart, hours ago. Everything else was created in 2024-2025.

### Step 12. Confirm the mechanism
```bash
cat 06-token-test.txt
```
**Expect:** `AADSTS500011 ... resource principal ... not found`

### Step 13. The detail to plant at 5 minutes if they miss it
```bash
jq -r 'select((.downstream_remote_address|startswith("172.24"))|not)
       | "\(.downstream_remote_address)  \(.user_agent)"' 05-istio-access-log-sample.json
```
**Expect:** `10.40.7.212:60114  legacy-tms/3.2`
Every other caller is in-cluster. That one is on-prem — kubectl cannot fix it.

Nothing to reset; the evidence is read-only.

---

## PART D — Exercise 03 (stuck rollout)

### Step 14. Check the context AGAIN before anything here
```bash
kubectl config current-context    # k3d-sandbox
```
This exercise ends in a `delete`. Never skip this.

### Step 15. What they see
```bash
kubectl -n sbx-missions get pods
```
**Expect:** 2 Running (old ReplicaSet), 1 CreateContainerConfigError (new ReplicaSet)

### Step 16. Diagnose
```bash
POD=$(kubectl -n sbx-missions get pods --field-selector=status.phase!=Running -o name | head -1)
kubectl -n sbx-missions describe "$POD" | tail -20
```
**Expect:** `Error: configmap "sbx-missions-api-m-u" not found`

```bash
kubectl -n sbx-missions get rs
kubectl -n sbx-missions get cm
kubectl -n sbx-missions get deploy sbx-missions-api -o json \
  | jq -r '.spec.template.spec.containers[0].envFrom[].configMapRef.name'
```
**Expect:** two ReplicaSets; only `sbx-missions-api-chart` exists; the template needs both.

### Step 17. THE grading question
Ask them: **"Is the service up?"**
It is — but the Running pods use the same ConfigMap via `envFrom`, which resolves at container
start. Any eviction, drain or consolidation and they cannot restart either.
A senior candidate raises this unprompted.

### Step 18. Read the real content out of Terraform state
```bash
cd /workspaces/interview-senior-platform/exercises/03-k8s-envfrom-deadlock   # or wherever the repo is
jq -r '.resources[] | select(.type=="kubernetes_config_map_v1")
       | .instances[].attributes.data' state/common-datastore.tfstate.json
```

### Step 19. Recover
```bash
kubectl -n sbx-missions create configmap sbx-missions-api-m-u \
  --from-literal=DATASTORE__CLUSTER__SERVER='datastore-pl-0.internal.example.net' \
  --from-literal=DATASTORE__CLUSTER__TLS_CRT_KEY_FILE='/etc/certs/tls-combined.pem' \
  --from-literal=DATASTORE__CLUSTER__CONNECTION_STRING='mongodb+srv://datastore-pl-0.internal.example.net/?authSource=%24external&authMechanism=MONGODB-X509&retryWrites=true&w=majority&readPreference=secondaryPreferred&appName=missions-api'
```

### Step 20. Watch it heal
```bash
kubectl -n sbx-missions rollout status deploy/sbx-missions-api --timeout=120s
kubectl -n sbx-missions get pods
```
**Expect:** stuck pod goes Running within ~30s, old pods terminate, rollout completes.

### Step 21. Reset for the next candidate
```bash
kubectl -n sbx-missions delete cm sbx-missions-api-m-u
kubectl -n sbx-missions rollout restart deploy/sbx-missions-api
sleep 25
kubectl -n sbx-missions get pods    # back to 2 Running + 1 failing
```

---

## PART E — Exercise 04 (is it healthy)

### Step 22. Read it as they would
```bash
cd ../04-is-it-healthy/evidence
cat 01-question.md 02-prometheus.txt 03-pod-status.txt
```
Two sources say healthy.

### Step 23. The source that disagrees
```bash
grep -n 'ERR\|Request finished' 04-app-log-sample.txt
```
**Expect:** an `ERR` with a NullReferenceException, then `Request finished ... - 200 - 41.8ms`
The exception is caught; the request returns 200. Metrics are accurate and answering the wrong
question.

### Step 24. Ground truth
```bash
cat 05-business-check.md
```
No leg created for a test order, twice.

**The answer:** yes it is still failing; no, monitoring will not show it; the only reliable signal
is whether the work happened.

---

## PART F — Exercise 05 (design)

### Step 25. Read the prompt
```bash
cd ../../05-identity-design && cat EXERCISE.md
```
Pure discussion. The thing to listen for: a client ID is **not** a secret. Candidates who notice
that have found the real design space.

---

## PART G — final reset

### Step 26. Leave it clean
```bash
cd /workspaces/interview-senior-platform
git checkout .
git status --short          # should be empty
kubectl -n sbx-missions get pods   # 2 Running, 1 CreateContainerConfigError
cd exercises/01-go-spec-guard && go run . hack/ui-spec.yaml ; echo "exit=$?"   # exit=0
```

If all three match, the environment is candidate-ready.
