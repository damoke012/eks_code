# Exercise 04 — Sketch a Terraform state split (INTERVIEWER SOLVE NOTES)

**For interviewer eyes only. Never share with candidates. Never push to a public/candidate-facing repo.**

## What the exercise tests

There's no code to write. This is a **design conversation** — about 10 minutes — testing senior judgment on a problem most companies hit at some point.

We're testing:

1. **State as blast radius** — do they see Terraform state as a design boundary, not just a tool detail?
2. **Migration discipline** — can they move resources without applying the world?
3. **Coordination thinking** — do they think about humans, not just tooling?
4. **Recovery mindset** — do they have a real rollback plan or do they hand-wave?
5. **Scale awareness** — do they understand how the answer changes with team size + resource type?

A senior who's done a state split for real will have war stories. A senior who hasn't will reason from first principles correctly. A mid will know the keywords but not the failure modes. A junior will say "use Terragrunt" without explaining why.

## The four questions and the framework they build

The four questions test four facets of state thinking:

| Q | What state really is | What we're testing |
|---|---|---|
| Q1 | **state = blast radius** | Can you design for survival of org change? |
| Q2 | **state = change discipline** | Can you move without applying? |
| Q3 | **state = single point of contention** | Can you keep humans out of each other's way? |
| Q4 | **state = safety net thinking** | Recovery mindset, or trusting luck? |

A senior who connects these four facets is showing they think about state as a high-stakes mutable object. That's the bar.

---

## Q1 — Target topology (where to draw boundaries)

### Layer 1 — what the candidate sees

> "How many root modules / states would you end up with, and where do you draw the boundaries? Why those boundaries?"

### Layer 2 — plain English

"You inherited 8,000 resources in one state. Where do you cut, and why? The wrong answer is 'split it into smaller pieces' — that doesn't say WHY."

### Layer 3 — mechanism (what makes a good state boundary)

A good state boundary follows **change-frequency + ownership lines**. The principles:

1. **Things that change together should live together** — splitting tightly-coupled resources means you have to coordinate two applies for one logical change
2. **Things that change independently should be separated** — IAM permission sets change weekly; VPC changes yearly. Don't make IAM changes wait for VPC plans.
3. **Blast radius matters** — `terraform destroy` in a state file kills everything that file owns. Keep "high-blast" resources (RDS, EKS) isolated from "low-blast" (S3, IAM).
4. **Ownership = team lines** — if the platform team owns networking and product teams own apps, give them separate states. People shouldn't accidentally plan-changes outside their lane.
5. **Survive a reorg** — the boundary should still make sense if teams reshuffle (it's about technical coupling, not org chart).

### Layer 4 — what good answers look like

For the inherited monolith, a strong answer might be **5-7 root modules**:

| Module | What's in it | Why |
|---|---|---|
| `networking` | VPC, subnets, NAT, TGW attachments | Changes rarely; high blast radius; foundation for everything |
| `cluster` | EKS control plane, node groups, IAM for nodes, CSI drivers | Changes with version upgrades; depends on networking |
| `platform-addons` | cert-manager, ESO, Cilium, ingress-nginx, kyverno helm releases | Changes monthly; depends on cluster |
| `stateful-data` | RDS clusters, ElastiCache, OpenSearch | **HIGHEST blast radius**; isolate from everything else |
| `apps` | Per-app IAM roles, SM secrets, S3, ECR | Changes weekly; OK to be larger or split further per team |
| `org-iam` | SSO permission sets, cross-account roles | Changes monthly; org-wide |

A strong candidate explains the **why** for each cut. A mid candidate lists them without rationale.

### Layer 5 — fix / answer template

"I'd cut along change-frequency + blast-radius + ownership lines. Roughly 5-7 root modules. Stateful data gets its own state because it has the highest blast radius. Networking gets its own because it's the foundation everything depends on. Apps may split further per team if there are enough engineers."

### Layer 6 — probes

| Probe | Strong | Weak |
|---|---|---|
| "Why split stateful data out?" | "Highest blast radius — RDS destroy = data loss. Isolate to a state most engineers can't touch." | "Because it's stateful" (no reasoning) |
| "Why not just split everything by team?" | "Teams change. Tech coupling is more stable than org chart." | "Sure, that's fine" |
| "What's the cost of TOO many states?" | "Cross-state references become painful (remote state lookups). Plan/apply orchestration gets harder." | Doesn't see a downside |
| "Survive a reorg?" | "Networking is networking regardless of who owns it" | Designs by current team structure |

### Layer 7 — strong vs weak phrases

**STRONG**
- "Boundaries follow change-frequency + blast-radius + ownership."
- "Stateful data has the highest blast radius — its own state, restricted access."
- "Boundary should survive a reorg."

**WEAK**
- "Split by service." (Misses the "why".)
- "Use Terragrunt to manage them all." (Tooling answer, not design answer.)
- "Move it to Terraform Cloud." (Avoids the question.)

---

## Q2 — Migration steps (without applying the world)

### Layer 1 — what the candidate sees

> "Given a live, in-use state file, how do you move resources between states without `apply`ing the world?"

### Layer 2 — plain English

"You can't take downtime. You can't destroy and recreate. You have 8,000 resources in one state and you want them in 5+. How?"

### Layer 3 — mechanism

The key tools:

1. **`terraform state mv`** — moves a resource's address within a state file. STATE-FILE-ONLY. No cloud API calls. Renames the pointer.

2. **`terraform state pull` / `state push`** — pulls a state file as JSON (`pull`) or pushes a JSON file back as state (`push`). Useful for surgery + backup.

3. **`terraform state rm` + `terraform import`** — removes a resource from one state's inventory (it still exists in cloud), then imports it into a new state. Used for moving between root modules. **No applies. No cloud changes.**

4. **Backend reconfigure** — `terraform init -backend-config=...` migrates state between backends.

### Layer 4 — migration approach for the monolith

Strong candidate's outline:

1. **Phase 0 — Pre-flight**
   - Confirm S3 bucket versioning is ON (recovery layer)
   - Take a snapshot: `terraform state pull > backup-pre-migration-$(date).tfstate`
   - Document the existing state contents: `terraform state list > before.txt`
   - Inventory cross-references: which resources reference each other (these need extra care)

2. **Phase 1 — Set up target root modules** (no apply yet)
   - Create the new directory structures with their own backend configs
   - Write the resource definitions copy-pasted from the monolith
   - Do NOT run `terraform apply` — there's nothing to apply since the resources already exist

3. **Phase 2 — Migrate each resource group**
   - For each resource: `terraform state rm 'module.X.aws_vpc.main'` (in source) → `terraform import 'module.Y.aws_vpc.main' vpc-abc123` (in target)
   - Or alternatively: `terraform state mv` if both states share a backend (less common)
   - After each batch: run `terraform plan` in BOTH source and target — expected output is **no-op** in both
   - If non-zero diff: STOP, investigate, possibly reverse

4. **Phase 3 — Verify**
   - Both `terraform plan` outputs clean
   - Document the new state addresses for runbooks

### Layer 5 — common mistakes the candidate might make

- **`terraform destroy` then `apply`** — would actually destroy and recreate cloud resources. **DISQUALIFYING answer.**
- **`-target` flag everywhere** — bypasses dependency graph; often makes the problem worse. Worth pushing back on if they suggest it.
- **Using `terraform refresh`** — can be useful but the candidate should know it's just syncing state to cloud, not moving anything.

### Layer 6 — probes

| Probe | Strong | Weak |
|---|---|---|
| "Does `state mv` call AWS APIs?" | "No — state-file-only" | "I think so?" |
| "What's the difference between `state mv` and `state rm` + `import`?" | "mv works within a state, rm+import works across states" | Treats them the same |
| "How do you confirm a migration step worked?" | "`terraform plan` after — expect no-op" | No answer |
| "Could you use `-target` to migrate piece by piece?" | "Possible but bypasses dependency graph; risky" | "Yes, that's the way" |

### Layer 7 — strong vs weak phrases

**STRONG**
- "State mv is state-file-only — no cloud calls."
- "Across states, it's rm + import."
- "After each batch, plan to confirm no-op."
- "Versioning + pre-migration backup before I touch anything."

**WEAK**
- "Destroy and recreate." ← DISQUALIFYING.
- "Use -target." ← Misunderstands the tool.
- "Terragrunt handles it for me." ← Avoidance.

---

## Q3 — Coordination problem (humans not racing)

### Layer 1 — what the candidate sees

> "How do you stop people from racing each other during the migration?"

### Layer 2 — plain English

"The migration takes hours-to-days. During that window, other engineers may try to make changes. How do you prevent them from corrupting the migration?"

### Layer 3 — mechanism

Three layers of coordination:

1. **Technical lock** — DynamoDB state lock prevents concurrent applies. But it doesn't prevent two engineers from racing PLANS or stomping each other's git pushes.

2. **Process lock** — communicate to the team that a migration window is open. Block PR merges to relevant modules. Pin the announcement.

3. **CI/CD lock** — disable auto-apply pipelines for affected modules during the window. Pause Atlantis/TFC if used.

For 5-engineer teams: Slack announce + calendar block is enough. For 50-engineer teams: you need explicit pipeline disable + a dedicated migration window + comms to stakeholders.

### Layer 4 — failure modes to flag

- **Stale plan, fresh apply** — Engineer A took plan, didn't apply, migration ran, A applies stale plan, state now wrong. Fix: invalidate plans, require fresh plan before apply.
- **PR merged during migration** — adds a new resource to monolith that you've already migrated. State now has the resource in both old AND new state.
- **Auto-apply pipeline** — Renovate or Dependabot opens a PR, CI runs apply, race.

### Layer 5 — answer template

Strong: "I'd announce a migration window in Slack + calendar. Block PR merges to affected modules. Disable auto-apply CI for those paths. Lock state via DynamoDB (which prevents concurrent applies). Communicate before, during, after. For a 50-engineer team, I'd also pause Atlantis or whatever the platform uses."

### Layer 6 — probes

| Probe | Strong | Weak |
|---|---|---|
| "DynamoDB lock — what does it actually prevent?" | "Concurrent applies on the same state — not concurrent plans" | "Concurrent everything" |
| "5 engineers vs 50 — different coordination?" | "5 = Slack + calendar. 50 = explicit pipeline disable + dedicated window" | "Same" |
| "Stale-plan problem — how do you prevent?" | "Invalidate plans; require fresh plan before apply" | Doesn't see the problem |
| "What if Renovate opens a PR during migration?" | "Pause Renovate, or merge-block the affected paths" | "It won't" |

### Layer 7 — strong vs weak phrases

**STRONG**
- "DynamoDB lock prevents concurrent applies, not plans."
- "Process lock matters as much as technical lock."
- "Disable auto-apply for affected paths during the window."
- "Comms before, during, after."

**WEAK**
- "DynamoDB handles it." (Doesn't know what the lock actually prevents.)
- "Just tell people not to push." (Won't survive 50 engineers.)
- Doesn't think about Renovate / Atlantis at all.

---

## Q4 — The rollback plan (the depth test)

### Layer 1 — what the candidate sees

> "What if a `state mv` goes wrong?"

The simplest-sounding question in the exercise. Don't be fooled — this is the question that separates "junior who can follow a runbook" from "senior who can write the runbook."

### Layer 2 — plain English

"You will fat-finger a source address, target the wrong state file, race a colleague's apply, or hit a lock timeout. **What's your safety net? Do you know what the safety net actually IS, or do you just say 'I'd revert it'?**"

Also tests whether they understand what state mv *actually does* — because if they think it touches cloud resources, their rollback plan will be terrifying.

### Layer 3 — mechanism

`terraform state mv` is **state-file-only**. Zero cloud API calls.

1. Acquires state lock (DynamoDB)
2. Downloads current state from S3
3. Rewrites the resource's *address key* in the state JSON
4. Writes new state back to S3 (S3 versioning preserves the old one — if enabled)
5. Releases lock

The actual EC2 instance, RDS cluster, IAM role don't move, don't change, don't even know anything happened. Only Terraform's *pointer* to them moves.

**This is why state mv is both safe (no cloud impact) and dangerous (silent).** A wrong state mv doesn't break immediately. It breaks on the *next plan/apply* — which could be hours later in a different engineer's hands.

### Layer 4 — runtime failure modes

**Scenario A — wrong destination address (typo)**
```
terraform state mv module.networking.aws_vpc.main module.netwroking.aws_vpc.main
```
Now state has a VPC at a non-existent module address. Next plan:
- `module.networking.aws_vpc.main` → not in state → **PLAN TO CREATE** new VPC
- `module.netwroking.aws_vpc.main` → in state but not in code → **PLAN TO DESTROY**

Colleague approves the plan without context. You just destroyed prod VPC.

**Scenario B — resource exists in TWO states (split migration bug)**
Moved into new state but forgot to remove from old (or vice versa). Both state files claim ownership. Whichever root module runs apply next, it'll see drift it didn't cause and "fix" it. The other state's apply will fix it back. Cloud-API ping-pong.

**Scenario C — partial migration / state corruption mid-flow**
Script fails after 200/500 moves. The state is now half-migrated. Source state thinks 300 resources still belong to it. Target state has 200 from this run plus 200 from a previous one. Lock may be held. Which state is canonical?

### Layer 5 — fix (the three-layer rollback plan)

#### Layer 1: S3 versioning + lock recovery
- **Pre-flight**: confirm `aws s3api get-bucket-versioning --bucket company-tf-state` returns `Enabled`. If not, turn it on before migration starts. **Non-negotiable.**
- **During**: capture object version IDs before each batch:
  ```bash
  aws s3api list-object-versions --bucket company-tf-state --prefix path/to/state | jq '.Versions[0]'
  ```
- **On failure**: `aws s3 cp s3://bucket/key?versionId=XYZ ./recovered.tfstate` → `terraform state push recovered.tfstate`

#### Layer 2: explicit backup (belt + suspenders)
Before ANY `state mv`: `terraform state pull > backup-pre-mv-$(date +%Y%m%dT%H%M%S).tfstate`. Save outside the bucket (fate-sharing risk if the bucket itself is the problem). Record state serial number alongside.

#### Layer 3: blast-radius reduction
- **Plan after every mv** — expected output is no-op. If plan wants changes, something's wrong, STOP.
- **Rehearse on a clone first**: `terraform state pull > clone.tfstate`, set up sandbox backend, run full migration there.
- **State list diff**: capture `terraform state list` before and after; visually confirm.

#### Reverse operations

**Reverse a single state mv** — swap source and destination:
```bash
terraform state mv module.netwroking.aws_vpc.main module.networking.aws_vpc.main
```

**Reverse a full migration**:
```bash
terraform state push backup-pre-mv-20260605T1530.tfstate
```
But this overwrites — so if apply happened between mv and rollback, you'll lose those changes too. Always rollback BEFORE the next apply.

**Special case: `state rm`** doesn't preserve the source location. To "reverse" a `state rm`, you have to `import` the resource back. Rollback path is fundamentally different from mv. Worth a candidate flagging.

### Layer 6 — probes

| Probe | Strong | Weak |
|---|---|---|
| "Does `state mv` call AWS APIs?" | "State-file only, no cloud calls" | Thinks it moves the cloud resource |
| "What does S3 versioning give you here?" | "Point-in-time state snapshots via versionId" | "I'd restore from backup" (vague) |
| "Rolling back mv vs rolling back rm?" | "rm has no source to swap; need import or push backup" | Treats them the same |
| "State-mismatch vs real drift — how to tell?" | "Plan after rollback — expect no-op; if not, real drift" | No clear answer |
| "Cloud resource changed during migration window?" | "Drift detected by plan; targeted refresh/import" | "Shouldn't happen" (denies reality) |
| "If versioning was off, what would your plan look like?" | "Step 1: turn it on. I wouldn't migrate without it." | "We'd be in trouble" |

### Layer 7 — strong vs weak phrases

**STRONG**
- "Before I start, I `terraform state pull` to a timestamped backup."
- "S3 versioning gives me point-in-time recovery via versionId."
- "Reverse a single mv by swapping source and dest."
- "After rollback, I run plan and expect no-op — if not, something else moved."
- "I rehearse on a state clone before touching prod state."
- "I expect zero diff on plan after each mv. Non-zero means stop."

**WEAK / RED FLAG**
- "I'd revert the git commit." ← **State is not in git.** Critical misunderstanding.
- "I'd run `terraform destroy`." ← Would actually destroy cloud resources. **Disqualifying.**
- "Use a backup." ← What backup? Where? Mechanism unknown.
- "It can't go wrong because we test in dev first." ← Misses the question.
- "I'd ask Vibin." ← Deflection. Fine as fallback but should have technical answer first.

---

## Bonus questions (5 vs 50 engineers; stateful vs declarative)

These come at the end. Strong candidates pick up these clues without prompting.

### "5 vs 50 engineers"

**STRONG**:
- Coordination scales nonlinearly. 5 = a Slack channel + a calendar block. 50 = you need Atlantis/TFC/Spacelift, an explicit migration window with broadcast, possibly a dedicated migration team.
- More engineers also means more state drift detection runs, more PR contention, more chances for stale plans.

### "Stateful vs declarative resources"

**STRONG**:
- Stateful resources (RDS, EKS, OpenSearch, ElastiCache) accumulate side-state in the cloud — snapshots, parameter groups, managed nodegroups
- A wrong state mv on RDS followed by accidental destroy in apply = **data loss**
- I'd migrate stateful resources LAST, with the most rehearsal, treat as the riskiest part
- Declarative resources (IAM, S3 buckets, ECR repos) are easier: `terraform state push` rollback usually safe

A senior candidate who connects the bonus dots is showing they think about migrations as **risk-tiered work**, not as a uniform task.

---

## What to do during the exercise

### Open with

> "You inherited a single Terraform state file with about 8,000 resources. Plans take 18 minutes. Last week, an engineer accidentally destroyed the wrong subnet. The team's afraid to touch it. Sketch your migration plan on the whiteboard or in a doc. Don't write Terraform — walk us through it."

### While they work

- **Q1 sets the framing** — listen for "blast radius," "change frequency," "ownership." If they jump straight into Q2 mechanics, redirect: "Before we talk steps, where are the boundaries?"
- **Q2 is the discipline test** — if they say "destroy and recreate" or "use -target everywhere," that's DISQUALIFYING. Note it.
- **Q3 is the humans test** — listen for who-talks-to-whom and what-gets-blocked. Weak candidates only think about tooling.
- **Q4 is the depth test** — most candidates can do Q1-Q3 OK; Q4 separates the senior from the mid. Strong: layered safety net. Weak: "I'd revert."

### When they finish

Ask the bonus questions to test scale awareness.

## Scoring rubric

| Tier | Signal |
|---|---|
| **STRONG hire** | Q1: clean boundary framework (blast radius + change freq + ownership). Q2: rm+import without apply; backup before. Q3: process + tooling + comms; differentiates team sizes. Q4: layered rollback with versioning + backup + rehearsal; explicitly distinguishes mv vs rm rollback. Bonus: connects stateful risk to rollback. |
| **Hire** | Q1: reasonable boundaries with some rationale. Q2: knows state mv vs rm+import. Q3: thinks about coordination but mostly tooling. Q4: knows S3 versioning helps; rollback plan exists but layered thinking is shallow. |
| **Borderline** | Q1: lists boundaries without rationale. Q2: knows state commands but mechanism is fuzzy. Q3: tooling-only thinking. Q4: vague rollback ("there's a backup somewhere"). |
| **No hire** | Q1: "split by service." Q2: "destroy and recreate." Q3: "DynamoDB handles it." Q4: "revert the git commit" / "run terraform destroy." Any disqualifying answer in Q2 or Q4. |

## Time budget

- ~10 min total — design conversation
- 2-3 min per question
- Move on if they're flailing; depth matters more than completing 4/4

If they nail Q1+Q2 and stall on Q3, push them: "What's the human side?"
If they nail Q1+Q2+Q3 and stall on Q4, push hard — that's the senior gate.
