# Exercise 02 — Triage 3 broken pods in Kubernetes (INTERVIEWER SOLVE NOTES)

**For interviewer eyes only. Never share with candidates. Never push to a public/candidate-facing repo.**

## What the exercise tests

This is not a "do you know kubectl commands" test. It tests:

1. **Diagnostic discipline** — does the candidate diagnose first, or jump to fixes?
2. **Symptom-vs-cause separation** — OOMKilled is a symptom; the cause is memory request too low *or* the app actually leaks
3. **Reading what the system is telling you** — events, logs, describe, status — not random guesses
4. **Recovery-mindset** — can they fix safely without making it worse?
5. **Production sense** — do they think about monitoring/alerting on these failure classes?

We care more about **how they reason** than how fast they fix. A candidate who fixes 3/3 but can't explain why is weaker than one who fixes 2/3 and explains both fixes + the third one's cause.

## Cluster setup (for your reference)

- Local k3d, namespace `broken`
- Three pods, three different failure modes:
  - `pod-a-memory` — OOMKilled (memory limit 32Mi, allocates 80Mi)
  - `pod-b-imagepull` — ImagePullBackOff (image tag typo)
  - `pod-c-config` — CrashLoopBackOff (ConfigMap key mismatch)

The pods are in `exercises/02-k8s-broken-pods/manifests/`. Hide these from the candidate — they should diagnose from the cluster, not from reading the YAML.

---

## Pod A — OOMKilled (memory)

### Layer 1 — what the candidate sees

```
NAME           READY   STATUS      RESTARTS   AGE
pod-a-memory   0/1     OOMKilled   3 (45s)    2m
```

Restart count climbing, status oscillating between `OOMKilled` → `CrashLoopBackOff`.

### Layer 2 — plain English (what's actually wrong)

Memory limit is 32Mi. App allocates ~80Mi. Kernel OOM-killer kills the container. Kubelet restarts it. Repeat.

### Layer 3 — mechanism (how OOMKill works)

- Container runtime sets a cgroup memory limit equal to `resources.limits.memory`
- Linux kernel enforces it — when the cgroup tries to allocate beyond the limit, **kernel OOM-killer kills the process inside the container**
- Exit code 137 = 128 + 9 (SIGKILL). This is the "OOMKill signature."
- Kubelet sees the container exit, restarts per `restartPolicy: Always`
- Eventually backoff kicks in → `CrashLoopBackOff`

The OOMKill happens **inside the container, killed by the kernel** — not by Kubernetes' scheduler. This is important: the pod stays scheduled on the same node, the kubelet just keeps restarting it.

### Layer 4 — diagnostic path (what should the candidate do?)

```bash
kubectl -n broken describe pod pod-a-memory
```

Look for:
- `Last State: Terminated, Reason: OOMKilled, Exit Code: 137`
- `Events:` table at the bottom — kubelet logs the kill

Strong candidate also runs:
```bash
kubectl -n broken get pod pod-a-memory -o jsonpath='{.spec.containers[0].resources}'
```
to see the limits without opening the YAML.

### Layer 5 — fix (and what "good" looks like)

The naive fix: bump `limits.memory` from 32Mi to 128Mi. **This works but it's weak.**

The strong answer:
1. Confirm the memory usage is real (not a leak): `kubectl top pod pod-a-memory` shows ~80Mi sustained → real usage, not a leak
2. Set `requests` and `limits` both — `requests` informs scheduler, `limits` enforces. Don't leave `requests` lower than reality.
3. **Important**: pod memory limit is **immutable**. You cannot `kubectl edit pod` to change it. Strong candidate knows you must delete+recreate (or use a Deployment).
4. Long-term: profile the app. If it actually needs 80Mi, set limit to 128Mi (50% headroom for GC, spikes). If it has a leak, the limit just delays the kill.

### Layer 6 — probes to ask

| Probe | What you're testing |
|---|---|
| "Why exit code 137?" | Do they know it's SIGKILL → kernel OOM, not a graceful shutdown |
| "Could you just bump the limit?" | Do they distinguish symptom-fix from cause-fix |
| "What's the difference between OOMKilled and CrashLoopBackOff?" | Do they understand status transitions |
| "Can you `kubectl edit pod` to change `limits.memory`?" | Do they know pod fields are mostly immutable |
| "If memory grew slowly over hours instead of seconds, would your fix change?" | Do they think about leaks vs steady-state |

### Layer 7 — strong vs weak phrases

**STRONG**
- "Exit 137 = SIGKILL from kernel OOM-killer, not Kubernetes."
- "I'd `kubectl top` to confirm actual usage before changing limits."
- "Limit is immutable on a Pod — needs delete+recreate, or use a Deployment."
- "I'd set requests to actual usage and limits with 50% headroom."
- "If usage grows over time it's a leak — the limit fix is a band-aid."

**WEAK / RED FLAG**
- "Just bump the memory." (No diagnostic step.)
- "I'd edit the pod with `kubectl edit`." (Doesn't know pod field immutability.)
- "Delete the pod and it'll come back fine." (Misses the cause.)
- Doesn't recognize exit 137. (Has not worked with OOM in real life.)

---

## Pod B — ImagePullBackOff (typo in image tag)

### Layer 1 — what the candidate sees

```
NAME              READY   STATUS             RESTARTS   AGE
pod-b-imagepull   0/1     ImagePullBackOff   0          2m
```

Goes through `ErrImagePull` first, then `ImagePullBackOff` as kubelet backs off.

### Layer 2 — plain English

Either the image tag doesn't exist (typo, wrong tag), or the image registry returns 403 (no auth/wrong secret). These look identical at status level but are completely different fixes.

### Layer 3 — mechanism

- Kubelet calls the container runtime → runtime calls the registry API
- 404 = no such image/tag (typo class)
- 401/403 = auth class (missing imagePullSecret, wrong creds, or expired token)
- Kubelet wraps both as `ErrImagePull` then `ImagePullBackOff` (after a few retries)

### Layer 4 — diagnostic path

```bash
kubectl -n broken describe pod pod-b-imagepull
```

The **events** section is where the truth lives:
- `Failed to pull image "nginx:1.99-this-tag-does-not-exist": ... manifest unknown` → typo class
- `Failed to pull image ... unauthorized: authentication required` → auth class

Strong candidate distinguishes these two cases without prompting.

### Layer 5 — fix

For typo class (this exercise): fix the image tag in the manifest. Either rebuild the pod with a real tag (e.g., `nginx:1.27`) or change to known-good `nginx:latest` for the exercise.

For auth class (not this exercise but the discussion is the point):
- Check `imagePullSecrets` on the Pod or its ServiceAccount
- Confirm the Secret exists, is of type `kubernetes.io/dockerconfigjson`
- For ECR: confirm the IRSA role on the SA has `ecr:GetAuthorizationToken`

**Strong candidate notes**: the container name `ngninx` is also a typo, but that's not the cause — just a hint about general sloppiness.

### Layer 6 — probes to ask

| Probe | What you're testing |
|---|---|
| "How do you tell typo from auth?" | Do they read the events correctly |
| "If it were ECR, what auth path would you check?" | Do they understand registry auth (IRSA, kubelet IAM, imagePullSecret) |
| "How long until kubelet stops retrying?" | Do they know about `ImagePullBackOff` exponential backoff (not "stops trying" — backs off) |
| "What's the worst case for ImagePullBackOff in prod?" | Strong: rolling deploy with bad tag → all new replicas stuck → traffic served by old until rollback |

### Layer 7 — strong vs weak phrases

**STRONG**
- "I read the events section — the message tells me 404 vs 401."
- "ECR auth is usually IRSA on the kubelet node role or the SA, depending on cluster config."
- "Pod-level imagePullSecrets are the fallback when SA doesn't have them."
- "Kubelet backs off exponentially, doesn't give up."

**WEAK / RED FLAG**
- "I'd delete the pod and retry." (Doesn't address the cause.)
- "Probably the registry's down." (Jumps to external cause without checking.)
- Doesn't know to look at events. (Has never debugged this in real cluster.)

---

## Pod C — CrashLoopBackOff (ConfigMap key mismatch)

### Layer 1 — what the candidate sees

```
NAME           READY   STATUS             RESTARTS   AGE
pod-c-config   0/1    CrashLoopBackOff   5 (30s)    3m
```

Restart count climbing. **Status alone does not tell you why.**

### Layer 2 — plain English

The container starts, can't find `DB_URL`, exits 1. Kubelet restarts. Backoff. The cause is in **the app's stdout**, not in events.

### Layer 3 — mechanism

- Container starts → runs entrypoint
- App reads env var `DB_URL` → unset
- App exits 1 with error message to stdout
- Kubelet sees exit, increments restart count, backs off exponentially
- After ~5 restarts, status flips to `CrashLoopBackOff`

The env var is set via:
```yaml
env:
  - name: DB_URL
    valueFrom:
      configMapKeyRef:
        name: app-config
        key: DB_URL          # <-- ConfigMap actually has key `database_uri`
```

The ConfigMap key reference is **wrong**. Kubelet tries to mount the env var, fails silently for optional keys (here it's required, so the pod might also fail to start with `CreateContainerConfigError` depending on K8s version — but in this exercise the env var is just empty).

### Layer 4 — diagnostic path

```bash
kubectl -n broken describe pod pod-c-config
```
Events may say `CrashLoopBackOff` but won't tell you WHY.

```bash
kubectl -n broken logs pod-c-config
```
Shows the CURRENT container's stdout. If it just restarted, you get the new attempt.

**The killer command**:
```bash
kubectl -n broken logs pod-c-config --previous
```
Gets the previous (crashed) container's logs. Shows: `ERROR: DB_URL is not set; cannot start`.

Then:
```bash
kubectl -n broken get cm app-config -o yaml
```
Shows the ConfigMap has key `database_uri`, not `DB_URL`. Mismatch confirmed.

### Layer 5 — fix

Two valid fixes:

**Option A** (fix the pod): change `key: DB_URL` to `key: database_uri` in the pod manifest.

**Option B** (fix the ConfigMap): rename ConfigMap key from `database_uri` to `DB_URL`.

A strong candidate asks: which is the source of truth? In a real system, the ConfigMap is usually shared and renaming it could break other consumers — so fix the pod. But this is a judgment call. The senior signal is **asking the question**, not picking a side.

**Important**: pod env vars are also immutable. Pod must be deleted+recreated (or use a Deployment).

### Layer 6 — probes to ask

| Probe | What you're testing |
|---|---|
| "What does `--previous` do?" | Do they know it shows the prior container's logs |
| "Why doesn't `describe pod` tell you about the env error?" | Do they understand events vs logs — events are k8s-level, app errors are in logs |
| "If you rename the ConfigMap key, what's the risk?" | Do they think about shared state |
| "How would you reproduce this without the pod manifest?" | Do they think to inspect from the cluster only |
| "What about `CreateContainerConfigError` — when does that fire?" | Bonus: when the ConfigMap doesn't exist or the key is required and missing |

### Layer 7 — strong vs weak phrases

**STRONG**
- "I'd start with `logs --previous` — current logs are after the restart."
- "Events tell me kubelet-level state; logs tell me app-level state."
- "I'd check the ConfigMap before changing it — other pods might reference it."
- "Pod env is immutable — delete+recreate."

**WEAK / RED FLAG**
- "Just delete and recreate, it'll work." (Doesn't diagnose.)
- "Increase the restart count limit." (Misses the cause entirely.)
- Doesn't use `--previous`. (Has never debugged a crashloop in real life.)

---

## What to do during the exercise

### Open with

> "There are 3 pods in the `broken` namespace, each broken differently. Walk me through how you'd diagnose them. Talk out loud — I care more about how you think than how fast you fix."

### While they work

- **Don't intervene unless they're flailing for 5+ minutes**
- Track which commands they reach for first (events first = good; YAML inspect first = weaker — that's reading the answer key)
- Note if they distinguish symptoms from causes
- Note if they ask clarifying questions ("is this prod?" — bonus)

### When they finish a pod

Ask the **probes from Layer 6** for that pod. The probes test depth.

### When they finish all 3 (or run out of time)

> "Talk through what you'd add to monitoring/alerting so you'd see these classes of failure proactively — not just when a user reports it."

This is the **production-sense gate**. A senior candidate should mention:

- **kube-state-metrics** → exports `kube_pod_status_reason` and restart counts as Prometheus metrics
- **Prometheus + AlertManager** → alert rules on `kube_pod_container_status_waiting_reason{reason="ImagePullBackOff"}` or restart-rate spikes
- **PagerDuty integration** → page on per-namespace pod-not-ready ratios
- **Grafana dashboard** → pod state distribution over time
- **Distinct alert classes**: OOM (memory tuning issue), ImagePullBackOff (release / registry issue), CrashLoopBackOff (config / code issue) — each should page a different team or runbook
- **Optional bonus**: SLO on "% of pods running successfully" or rollout success rate, with alerts on slow burn vs fast burn

A weak answer is "Datadog or Prometheus" with no specifics.

## Common candidate races / gotchas

### The pod immutability race

If the candidate runs `kubectl delete --wait=false` then immediately `kubectl apply -f`, the apply will hit a still-Terminating pod and try to PATCH it, getting:
```
Forbidden: pod updates may not change fields other than spec.containers[*].image, ...
```
**This is gold** — interrupt and ask: "Why did that happen?" They should explain pod field immutability. If they don't know, walk them through:

- Pods are designed to be immutable except for a small set: image, activeDeadlineSeconds, tolerations
- Memory limits, env vars, command — all immutable
- This is why Deployments exist: they create new ReplicaSets / new pods rather than mutate

### "Should I open the YAML?"

Strong candidates resist this until they've diagnosed from the cluster. Weak candidates open the YAML first thing — they're reading the answer key. Note which one they are.

## Scoring rubric

| Tier | Signal |
|---|---|
| **STRONG hire** | Diagnoses 3/3 from cluster signals only. Distinguishes symptoms from causes. Uses `--previous`. Knows pod immutability. Mentions kube-state-metrics by name. Asks clarifying questions. |
| **Hire** | Diagnoses 2-3. May skip one of the production-sense items. Reasoning is sound. Uses events + logs correctly. |
| **Borderline** | Fixes pods but reasoning is shallow. Misses `--previous` until prompted. Doesn't volunteer monitoring discussion. |
| **No hire** | Fixes by trial-and-error (delete and recreate, bump random values). Doesn't read events. Confuses logs with events. No production sense. |

## Time budget

- ~20 min total
- 5 min per pod = 15 min
- 5 min monitoring discussion at end

If they're stuck on pod 1 at minute 10, redirect them: "Skip this for now, look at pod 2 — we'll come back."
