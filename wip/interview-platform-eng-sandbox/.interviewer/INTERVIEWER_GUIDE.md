# Interviewer Guide — Platform Engineering Sandbox

**This dir is INTERVIEWER-ONLY.** Candidates technically can see it, but you'll brief them not to open it. If you want stricter separation, move this dir to a private companion repo.

## Before the interview

1. **Spin up the codespace 10 min before** — `Codespaces → New from this repo → 4-core machine`.
2. Wait for `post-create.sh` to finish (~3 min — installs k3d, creates cluster, deploys broken pods).
3. Verify: `kubectl get nodes` (2 nodes), `kubectl -n broken get pods` (3 pods in broken states), `cd exercises/01-go-mage-mini && go test ./...` (all pass).
4. **Share the URL** with the candidate via Teams chat. The URL looks like `https://CODESPACE-NAME.github.dev` or the in-browser editor link.
5. They open in their browser. No GitHub permissions issue — you can use Codespace Live Share or send the read-write link.

## Time budget (75 min)

| Min | What |
|---|---|
| 0-5 | Greet, confirm they can see + run things, open README |
| 5-15 | Verbal — deepen the screening (probe their most recent platform story; ask 2 specific Mage/DX-style "build vs buy" questions) |
| 15-35 | **Exercise 01 (Go)** — *make-or-break* |
| 35-55 | Exercise 02 (K8s broken pods) |
| 55-65 | Exercise 03 (AWS IAM) |
| 65-72 | Exercise 04 or 05 (whichever fits — design conversation) |
| 72-75 | Their questions, wrap |

## How to watch them work

- Have them share their screen in Teams (Codespace tab + a terminal)
- You stay quiet for the first 2-3 minutes of each exercise to see how they start
- After that, ask probing questions or nudge if they're stuck
- Take real-time notes against the **scoring rubric** (next file)

---

# Exercise 01 — Go solutions

## What the Kafka block should look like

In `internal/spec/spec.go`:

```go
type Kafka struct {
	TopicName        string `yaml:"topic_name" validate:"required,min=1"`
	PartitionCount   int    `yaml:"partition_count" validate:"required,min=1"`
	ReplicationFactor int   `yaml:"replication_factor" validate:"required,min=1,max=5"`
	RetentionHours   int    `yaml:"retention_hours,omitempty" validate:"omitempty,min=1" default:"24"`
}
```

In the `Spec` struct, add:

```go
Kafka *Kafka `yaml:"kafka,omitempty" validate:"omitempty"`
```

Pointer is correct because that's how we know "kafka block omitted" vs "kafka block present but invalid".

## New tests

```go
func TestValidate_Kafka_Happy(t *testing.T) {
    s := &Spec{
        Name: "demo", Octopus: Octopus{Space: "USXpress", Group: "platform"},
        Kafka: &Kafka{
            TopicName:         "demo-events",
            PartitionCount:    3,
            ReplicationFactor: 3,
            RetentionHours:    168,
        },
    }
    require.NoError(t, Validate(s))
}

func TestValidate_Kafka_BadPartition(t *testing.T) {
    s := &Spec{
        Name: "demo", Octopus: Octopus{Space: "USXpress", Group: "platform"},
        Kafka: &Kafka{
            TopicName: "demo", PartitionCount: 0,
            ReplicationFactor: 3,
        },
    }
    err := Validate(s)
    require.Error(t, err)
    assert.Contains(t, err.Error(), "PartitionCount")
}
```

## Signals to grade on

| Signal | Senior | Mid | Junior |
|---|---|---|---|
| Reads `spec.go` before writing new code | Always | Sometimes | Rarely |
| Uses validator tags vs `if` blocks | Tags | Mix | `if` blocks |
| Pointer vs value for optional block | Pointer with `omitempty` | Value (works but slightly wrong) | Doesn't know the distinction |
| Test discipline | Table tests, positive + negative | One happy path | Skips tests |
| Error wrapping | `%w` + context | Raw error | Bare `fmt.Println` |
| Asks clarifying questions | Several | One or two | None |
| Catches the `validate:"required,min=1"` redundancy | Yes (knows `required` implies non-zero for ints) | Maybe | No |
| Handles default `RetentionHours` correctly | Yes — uses `defaults.Set` + `default:"24"` tag | Defaults inline in code | Doesn't implement defaults |

**Pass bar for senior:** Working Kafka block with validator tags, pointer for optional, at least one negative test, defaults working via the existing pattern. ~12-18 min for senior.

**Disqualifier:** Can't read existing pattern; rewrites validation logic in `if` blocks; can't get tests to pass.

---

# Exercise 02 — K8s broken pods solutions

## Pod A (`pod-a-memory`) — OOMKilled

- **Symptom:** `OOMKilled` status, restart count climbing
- **Root cause:** `stress` allocates 80MB, limit is 32MB
- **Senior diagnosis path:** `describe` → see Last State: Terminated, Reason: OOMKilled → check `resources.limits.memory` (32Mi) → check what the workload actually needs → realize 80M > 32Mi
- **Fix:** Bump memory limit OR (if this were real) profile the workload and fix the leak

**What good sounds like:** "OOMKilled. Before I bump the limit I want to know if this is a misconfigured limit or a runaway allocation. Stress is contrived but in prod I'd check the workload's actual usage with `kubectl top` and `cadvisor`. Here the limit is clearly too low for the declared workload — bumping to 128Mi is fine. In real life I'd also add a VPA recommendation and a request to match."

## Pod B (`pod-b-imagepull`) — ImagePullBackOff

- **Symptom:** `ErrImagePull` → `ImagePullBackOff`
- **Root cause:** Image tag `nginx:1.99-this-tag-does-not-exist` doesn't exist
- **Senior diagnosis path:** `describe` → events show "Failed to pull image ... not found" → check `image:` field → realize tag is bogus
- **Fix:** Update image tag to a real one (`nginx:1.25` or similar)

**What good sounds like:** "ImagePullBackOff. Distinguishing causes: no-such-image vs no-auth-to-pull. Events here say 'not found' — that's the first case. Auth would say 'unauthorized' or 'forbidden'. Fix: real tag. In prod I'd want a CI gate that resolves the image tag before merging."

**Bonus signal:** Catches the `ngninx` container name typo as a smell (irrelevant but shows attention).

## Pod C (`pod-c-config`) — CrashLoopBackOff

- **Symptom:** Container exits 1 immediately, kubelet restarts, backoff
- **Root cause:** `envFrom` references key `DB_URL` but ConfigMap has key `database_uri`
- **Senior diagnosis path:** `describe` → CrashLoop with exit 1 → `kubectl logs pod-c-config --previous` shows "ERROR: DB_URL is not set" → check the env source → see configMapKeyRef expects key `DB_URL` → check the ConfigMap → realize key is `database_uri`
- **Fix:** Either rename the key in the ConfigMap to `DB_URL`, or change the `configMapKeyRef.key` to `database_uri`

**What good sounds like:** "CrashLoop with `--previous` logs telling me exactly what's wrong: DB_URL is missing. Now I look at the env source. The ref says key DB_URL but the ConfigMap has database_uri. Fix the mismatch. In prod the right fix depends on who owns each — if other consumers depend on database_uri, change the pod manifest; if the pod is authoritative, change the ConfigMap."

## Senior signal across all three

- Says **"I'll diagnose before fixing"** unprompted
- Goes to `--previous` for crashed containers automatically
- Distinguishes `kubectl logs` (container stdout) from app-level log files inside the container
- Mentions monitoring follow-ups (alerts on OOMKill, on Crash count, on ImagePullErrors)

## Mid signal

- Goes to `describe` correctly but jumps to fix without reading events fully
- For OOM, suggests "bump memory" immediately

## Disqualifier

- Doesn't know `kubectl logs --previous`
- Can't articulate the difference between ImagePullBackOff causes
- Suggests `kubectl edit` or `delete pod` as primary debugging tools

---

# Exercise 03 — AWS cross-account IAM solutions

## Bug #1 — wrong permissions on source role

```hcl
# WRONG: pod role tries to read secret directly across accounts
resource "aws_iam_role_policy" "pod_source_perms" {
  policy = jsonencode({
    Statement = [{ Action = "secretsmanager:GetSecretValue", Resource = "arn:...account_b..." }]
  })
}
```

**Correct:**

```hcl
# Source role should only have AssumeRole into B
resource "aws_iam_role_policy" "pod_source_perms" {
  policy = jsonencode({
    Statement = [{
      Action   = "sts:AssumeRole"
      Resource = "arn:aws:iam::${var.account_b_id}:role/cross-account-secret-reader"
    }]
  })
}
```

## Bug #2 — trust policy is wide open

```hcl
# WRONG
Principal = { AWS = "*" }
```

**Correct:**

```hcl
Principal = {
  AWS = "arn:aws:iam::${var.account_a_id}:role/demo-pod-secret-reader"
}
Condition = {
  StringEquals = {
    "sts:ExternalId" = "shared-secret-known-only-to-both-sides"
  }
}
```

## Bug #3 — missing resource policy on the secret

```hcl
# ADD: resource policy on the secret in account B
resource "aws_secretsmanager_secret_policy" "demo_db_creds" {
  provider   = aws.account_b
  secret_arn = "arn:aws:secretsmanager:us-east-1:${var.account_b_id}:secret:demo-app/db-creds"

  policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.cross_account_reader.arn }
      Action    = "secretsmanager:GetSecretValue"
      Resource  = "*"
    }]
  })
}
```

## Senior signals

- Says **resource policy + IAM policy** unprompted — the duality
- Mentions ExternalId + the confused-deputy attack
- Knows IRSA vs Pod Identity tradeoffs
- Knows `MaxSessionDuration` (1h default, up to 12h)
- Mentions CloudTrail in *both* accounts for debugging

## Mid signals

- Fixes the trust policy but doesn't mention the resource policy
- Doesn't mention ExternalId

## Disqualifier

- Says blanket Principal: AWS = "*" is "fine, we have other controls"
- Doesn't know what AssumeRole is
- Can't trace the auth chain (SA → IRSA → STS → AssumeRole → SM)

---

# Exercise 04 — TF state split solutions

## What good looks like

### Target topology (~5 root modules)

1. **`networking/`** — VPC, subnets, NAT, TGW, route tables. Slowest to change.
2. **`cluster/`** — EKS, node groups, OIDC, csi drivers. Depends on networking via remote_state.
3. **`platform-addons/`** — cert-manager, ESO, Cilium, ingress, kyverno (typically helm_release).
4. **`stateful-data/`** — RDS, ElastiCache, OpenSearch. Slow lifecycle, careful changes.
5. **`apps/<app>/`** — per-app infra. ~80 separate states. Each owned by app team.

### Migration steps

For each chunk:

1. **Backup state** (S3 versioning helps, but also `terraform state pull > backup-$(date).json`)
2. **Freeze applies** on the source state (set a lock that blocks CI)
3. **Set up destination state** in the new root module (empty)
4. **For each resource:** `terraform state mv -state=source.tfstate -state-out=dest.tfstate ...` OR `state rm` from source + `import` into dest
5. **Run `terraform plan`** in destination — must show zero diff. If non-zero, attribute mismatch — debug.
6. **Run `terraform plan`** in source — must show zero diff. If non-zero, source still thinks it owns the resource — debug.
7. **Repeat** for each chunk in order: networking → cluster → addons → data → apps (least-coupled first).

### Coordination

- Terragrunt for DRY orchestration + dependency wiring
- Atlantis or TFC for PR-driven applies (no laptop applies)
- Lock the source state during migration via DynamoDB or Atlantis lock
- Single migrating engineer, pair-reviewed state mv commands

### Rollback

- S3 versioning lets you `s3 cp s3://bucket/state.tfstate.<previous-version-id> ./recovered.tfstate`
- `terraform state push` to restore
- But: if you've already applied changes between the mv and the realization, you have a real reconciliation problem

## Senior signals

- Splits by **lifecycle / coupling**, not by team
- Mentions Terragrunt / Atlantis / TFC
- Knows the difference between `state mv`, `state rm`, `import`
- Honest about the migration risk: "I'd do networking first because it has the fewest consumers"
- Mentions that `-target` is dangerous and not a real solution
- For scale answer: "More engineers = more PR-driven workflows + tighter locks"

## Disqualifier

- "Rewrite from scratch"
- Doesn't know `terraform state mv`
- Treats `-target` as the answer
- Splits purely by team without addressing lifecycle

---

# Exercise 05 — SLO solutions

## What good looks like

### SLI

`(2xx + 3xx responses with TTFB < 500ms) / (total non-internal-error responses)` measured at the ALB or ingress-nginx (NOT inside the pod).

Optionally a separate SLI for `/shipments/{id}/history` with a relaxed latency budget.

### SLO

- 99.9% over 28-day rolling window for primary endpoints
- 99.5% for `/history` (customers tolerate slow per the description)
- Budget math: 28d × 24h × 60m × 60s × 0.001 = 2,419s ≈ 40 min

### Burn rate alerts (Google SRE workbook)

- **Fast burn — page:** 2% of budget consumed in 1 hour (~14.4× normal burn). On-call pages.
- **Slow burn — ticket:** 10% of budget in 6 hours (~6× burn). Ticket, not page.
- One alert per SLO, not per metric

### Error budget policy

- **0-50% consumed:** business as usual
- **50% consumed:** SRE lead notified, review velocity
- **80% consumed:** freeze risky deploys, prioritize reliability work
- **100% consumed:** full deploy freeze except SLO-fixes; postmortem on root cause

### Explicitly NOT alerting on

- CPU > 80% — not user-impacting alone
- Memory > 80% — same
- Pod restarts (HPA handles, can be noisy)
- Cache miss rate spikes (cache cold-start after deploy is expected)
- Individual node failures (cluster handles)
- Kafka broker outage (fire-and-forget per description)

## Senior signals

- Measures at the **edge** (LB/ingress), not in the app
- Multi-window burn rate, not "alert when 5xx > 5%"
- Error budget policy is **a conversation with product**, not a unilateral engineering rule
- "200 with empty body when DB times out" — surfaces this as a separate SLI ("validity" or "completeness")
- For the 90% budget Q24/28: "I'd have a conversation with the product owner. We can carry the budget forward, or we can negotiate a temporary reduction to 99.5% if we have a real reason. We don't just panic-deploy a fix."

## Mid signals

- Picks 99.9% without justifying
- Has burn-rate alerts but only one window
- Doesn't separate `/history` SLO

## Disqualifier

- Uses CPU or memory as SLI
- Alerts on raw metric thresholds with no budget concept
- Says "9 nines" without justification

---

# Final scoring sheet

After all 5 exercises:

| Skill | Score (1-5) | Notes |
|---|---|---|
| Go fluency | | |
| K8s troubleshooting | | |
| AWS / cross-account IAM | | |
| Terraform at scale | | |
| Observability / SLO design | | |
| Architectural judgment | | |
| Reads code before writing | | |
| Asks clarifying questions | | |
| Honest about gaps | | |
| Communicates while working | | |

**Pass for Vibin replacement:** 4+ on Go, K8s, AWS; 3.5+ everything else.
**Below 4 on Go = disqualifier** for this specific role.

Decide same-day if possible. Don't let it linger past 48h.
