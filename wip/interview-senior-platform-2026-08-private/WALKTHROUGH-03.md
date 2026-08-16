# Exercise 03 — interviewer walkthrough

Copy-paste sequence for the stuck-rollout exercise, both recovery routes, and what to watch for.
**Interviewer-only.** Run these in your own codespace when rehearsing; during a round the candidate
drives and you watch.

---

## 0. Before anything — check the context

This exercise ends in a `delete`. Every time, without exception:

```bash
kubectl config current-context
```

Must read `k3d-sandbox`. If it names a real cluster, stop.

```bash
cd /workspaces/interview-senior-platform/exercises/03-k8s-envfrom-deadlock
```

---

## 1. Diagnose

```bash
kubectl -n sbx-missions get pods
```
→ 2 Running, 1 `CreateContainerConfigError`. Two different states means two ReplicaSets.

```bash
POD=$(kubectl -n sbx-missions get pods --field-selector=status.phase!=Running -o name | head -1)
kubectl -n sbx-missions describe "$POD" | tail -20
```
→ `Error: configmap "sbx-missions-api-m-u" not found`. This is the whole diagnosis.

```bash
kubectl -n sbx-missions get rs
```
→ old ReplicaSet 2/2, new one 1 desired / 0 ready. On a codespace that has been rehearsed in, extra
ReplicaSets at 0 appear — old revisions from previous `rollout restart`s. Harmless.

```bash
kubectl -n sbx-missions get cm
```
→ `sbx-missions-api-chart` exists, `sbx-missions-api-m-u` does not.

```bash
grep -A6 envFrom manifests/deployment.yaml
```
→ the pod template consumes both ConfigMaps. `envFrom` is resolved at container start, so a missing
one means the container never starts.

---

## 2. Ask this before they touch anything

> **"Is the service up or down? How confident are you?"**

It is up — two pods Running. But they consume the same ConfigMap via `envFrom`, resolved at
container start, so they survive only until something stops them. A node drain, an eviction, an
autoscaler consolidation, and they cannot restart.

Senior candidates say this unprompted and treat it as the reason to hurry. Mid candidates diagnose
correctly and miss that the healthy pods are load-bearing and fragile.

---

## 3. Read the values

The three `DATASTORE__CLUSTER__*` values exist in **one place only**:
`state/common-datastore.tfstate.json`. `manifests/` names the ConfigMap but not its contents.

```bash
grep -rln 'datastore-pl-0\|DATASTORE__CLUSTER' .
```
→ `state/common-datastore.tfstate.json` and nothing else.

Either of these is a fine way to read it — `jq` is convenience, not the test:

```bash
jq -r '.resources[] | select(.type=="kubernetes_config_map_v1") | .instances[].attributes.data' \
  state/common-datastore.tfstate.json
```

```bash
grep -oE '"DATASTORE__[A-Z_]+": "[^"]*"' state/common-datastore.tfstate.json
```

Opening the file in the editor counts too. Only be concerned if the values appear without the
candidate looking anywhere.

---

## 4a. Recover — the jq route

Builds the manifest straight from the platform's record. Cannot typo.

```bash
jq '[.resources[] | select(.type=="kubernetes_config_map_v1") | .instances[].attributes][0]
   | {apiVersion:"v1", kind:"ConfigMap",
      metadata:{name:.metadata[0].name, namespace:.metadata[0].namespace, labels:.metadata[0].labels},
      data:.data}' state/common-datastore.tfstate.json | kubectl apply -f -
```

Terraform stores `metadata` as a one-element array and has no `apiVersion`/`kind`, so the jq
reshapes its record into a Kubernetes manifest. `kubectl apply -f -` reads it from stdin.

## 4b. Recover — the kubectl route

Equally valid. Two commands, and the labels are a separate step because `kubectl create configmap`
has no flag for them.

```bash
kubectl -n sbx-missions create configmap sbx-missions-api-m-u \
  --from-literal=DATASTORE__CLUSTER__SERVER='datastore-pl-0.internal.example.net' \
  --from-literal=DATASTORE__CLUSTER__TLS_CRT_KEY_FILE='/etc/certs/tls-combined.pem' \
  --from-literal=DATASTORE__CLUSTER__CONNECTION_STRING='mongodb+srv://datastore-pl-0.internal.example.net/?authSource=%24external&authMechanism=MONGODB-X509&retryWrites=true&w=majority&readPreference=secondaryPreferred&appName=sbx-missions-api'
```

```bash
kubectl -n sbx-missions label configmap sbx-missions-api-m-u \
  app=sbx-missions-api \
  platform.example.io/environment=production \
  platform.example.io/project=sbx-missions-api \
  platform.example.io/revision=0.4.12
```

`label` before `create` fails with `NotFound`. Two things people get wrong from memory: the
connection string ends `appName=sbx-missions-api` (not `missions-api`), and the labels get dropped
entirely.

---

## 5. Verify

```bash
kubectl -n sbx-missions get cm sbx-missions-api-m-u --show-labels
kubectl -n sbx-missions rollout status deploy/sbx-missions-api --timeout=120s
kubectl -n sbx-missions get pods
kubectl -n sbx-missions get rs
```

Want: `DATA 3` with all four labels; `successfully rolled out`; **2 pods Running** (the Deployment
is `replicas: 2` — three pods is the *stuck* state, not the solved one); the new ReplicaSet at 2/2
and everything else at 0. A `Terminating` pod for a few seconds is the last old one draining.

---

## 6. Reset

```bash
kubectl -n sbx-missions delete cm sbx-missions-api-m-u
kubectl -n sbx-missions rollout restart deploy/sbx-missions-api
sleep 30 && kubectl -n sbx-missions get pods
```

→ 2 Running + 1 `CreateContainerConfigError`. Run `delete` and `rollout restart` together; never
`label` after a delete.

---

## What to look out for

**Good signals**

- Diagnoses from the cluster before opening `manifests/` or `state/`
- Distinguishes the stuck ReplicaSet from the working one, and says why they differ
- Raises the eviction risk on the healthy pods unprompted
- Goes to `state/` for the values rather than typing them
- Recreates the labels, not just the data — the platform's record and the cluster should agree
- Says what they expect *before* pressing enter on anything that writes

**Defensible, but push on it**

- `kubectl -n sbx-missions rollout undo deploy/sbx-missions-api` unsticks the deploy and is a
  legitimate mitigation. The costs: the intended configuration is still missing, and the platform
  reapplies the same broken state on the next deploy. Naming those is good reasoning. Calling it a
  fix is not.

**Concerning, worst first**

- `kubectl delete deployment` and let the platform recreate it — destroys the working pods, turns a
  degraded service into an outage
- Inventing plausible ConfigMap content — the pod starts, the rollout goes green, and the app
  quietly talks to the wrong datastore. A missing ConfigMap fails loudly; a wrong one fails silently
- Editing the live Deployment to drop the `envFrom` entry — same as `rollout undo`, no record
- Scaling to zero "for a clean start"

**The finish-early question:** a "clean" redeploy would have destroyed and recreated the app
registration — the Exercise 02 incident. Whether they connect the two unprompted is worth noting;
it is the same failure viewed from two ends.
