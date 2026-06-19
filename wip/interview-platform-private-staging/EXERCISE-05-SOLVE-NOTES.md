# Exercise 05 — Design SLIs + SLOs + alerting (INTERVIEWER SOLVE NOTES)

**For interviewer eyes only. Never share with candidates. Never push to a public/candidate-facing repo.**

## What the exercise tests

A 10-minute design conversation. There's no code to write. We're testing:

1. **Edge-vs-app measurement understanding** — do they know WHERE to measure and why it matters?
2. **Concrete math, not round numbers** — can they justify "99.9%" with budget math?
3. **Distinction between paging, ticketing, and dashboards** — do they think about who gets woken up at 3am?
4. **Error budget policy thinking** — do they understand the negotiating-with-product part?
5. **What NOT to alert on** — can they explicitly de-prioritize?

The service description (`api-description.md`) is the source of truth. Re-read it before the interview; it gives you specific failure modes (RDS failover, cache cold-start, deploy regression, Kafka outage) to probe.

A senior who's run SLOs in production will have opinions about the failure modes. A senior who hasn't will reason from first principles. A mid will name SRE book chapters without applying them.

## The service in one screen (from `api-description.md`)

- `shipment-tracking-api` — public REST, 12 replicas, behind ALB → ingress-nginx
- 3 read endpoints + 1 internal write endpoint
- 200-2000 RPS, peaks 4-5 PM ET
- p50 80ms / p95 250ms / p99 400ms
- Failure modes seen: RDS failover (~90s of 5xx), cache cold-start (2x p99 for 5 min), Kafka outage (0 HTTP impact — fire-and-forget), bad deploy with N+1 query (p99 → 8s)
- Customers: "99.9% loosely"; care most about freshness within 5 min of dispatch; do NOT care if `/history` is slow

That context is the test rubric. The candidate should be **reading the spec and reusing what's in it** — if they ignore the customer's actual concerns, that's a senior signal failure.

## The 5 sub-questions and how to grade them

The exercise has 5 sub-prompts; treat them as a sequence:

1. **SLIs** — what do you measure, where, why?
2. **SLOs** — what target, over what window, why those numbers?
3. **Alert rules** — what fires, at what thresholds, paging vs ticketing?
4. **Error budget policy** — what does the team do at 50% / 80% / 100% consumed?
5. **What NOT to alert on** — what would you de-prioritize?

---

# Q1 — The SLI (what / where / why)

## Layer 1 — what the candidate sees

> "What do you measure, where, and why?"

Open-ended on purpose. They could name 1, 3, or 10 SLIs; they could measure at any point in the stack. The "where" and "why" are the actual senior gates.

## Layer 2 — plain English (what's actually being tested)

"Can you pick the smallest set of numbers that, when they change, indicate the user is having a worse time? And do you know **where** to measure those numbers without me having to tell you?"

The wrong-flavor answer: "I'd measure CPU, memory, pod restarts, queue depth, error rate, latency..." — that's a dashboard, not an SLI set. SLIs should be **few** and **user-facing**.

## Layer 3 — mechanism (the three measurement points and their trade-offs)

This is the depth test. A senior knows three measurement options with explicit trade-offs:

| Measurement point | What you see | What you miss |
|---|---|---|
| **Inside the app** (app-emitted Prometheus metrics, OTel spans from app POV) | App-level request count, latency from app POV, business-event success | App can lie if buggy. If app is DOWN, you see zero (looks the same as "low traffic"). Misses cases where request never reached the app (DNS, ALB, nginx). |
| **At the ingress / edge** (nginx access logs, ALB metrics, sidecar like Envoy stats) | What the user actually experienced — full chain: network + ALB + nginx + app + downstream | More moving parts to instrument; need deliberate config. Volume can be high (200-2000 RPS × log line = real cost). |
| **From a synthetic prober** (Pingdom, CloudWatch Synthetics, custom canary in-cluster) | Availability from a known user perspective; geo-distributed | Doesn't see real-traffic patterns; samples too thin to catch P-tail. Useful as backstop, not primary SLI. |

**Strong candidates pick edge** for the SLI of record because:
- It's closest to user experience
- It survives the app being unreachable (ingress returns 503/timeout — that IS user-visible failure)
- App-side metrics are still useful, just as **supplementary diagnostics**

**Weak candidates pick in-app** without articulating the trade-off, or say "Prometheus" as if Prometheus tells you where to scrape.

## Layer 4 — what SLIs to actually pick for this service

For `shipment-tracking-api`, the grounded answer is **three SLIs**:

### SLI 1: Availability — % of HTTP requests returning non-5xx at the ingress

```
sli_availability = (total_requests - requests_with_5xx) / total_requests
```

Subtleties:
- **Exclude 4xx by default** — caller errors, not yours
- **Exception**: auth 401 storms might warrant a separate carve-out SLI
- **Window for measurement** is a count over time, not a single sample

### SLI 2: Latency — per-endpoint p99 at the ingress

```
sli_latency_get_shipment = % requests to GET /shipments/{id} with response time < 400ms (at p99)
```

Subtleties:
- **Per endpoint, NOT global** — spec says one endpoint is 70% of traffic, another nobody cares about. Mixing them hides regressions in both directions.
- **p95 vs p99**: p99 catches tail; p95 catches median-bad. Some teams measure both.

### SLI 3 — Freshness (the senior signal)

```
sli_freshness = % of newly-created shipments visible via GET /shipments/{id} within 5 min of dispatch
```

**This is the customer-stated need.** The spec explicitly says: *"Customers care most about: shipments visible within 5 min of dispatch creation."*

A strong candidate volunteers freshness as an SLI **without being told it's important**. Measurement options:
- Synthetic prober: create test shipment, poll until visible, record latency
- End-to-end timestamps: dispatcher emits creation timestamp; first GET records read-time delta

A senior who skips freshness is showing they're not reading the spec for user-meaning. Real gap.

## Layer 5 — what NOT to use as SLI

- **CPU % / Memory %** — *saturation* (one of the Golden Signals). Leading indicator, not user-facing. Page nobody.
- **Pod restart count** — internal cluster behavior, dashboard or ticket only.
- **DB connection pool usage** — leading indicator.
- **Cache hit rate** — leading indicator; affects latency but not SLI of record.
- **Kafka broker health** — spec literally says HTTP unaffected by Kafka. Don't make this an SLI.

General rule a senior articulates: **"If it's not something the user would notice, it's not an SLI of record."**

## Layer 6 — probes to ask

| Probe | Strong | Weak |
|---|---|---|
| "Why measure at the edge instead of inside the app?" | "App can lie, can be down. Edge sees user experience." | "It's just convenient" |
| "Should you include 4xx in availability?" | "Usually exclude — caller errors. Carve out auth 4xx separately if relevant." | "Yes, count everything" |
| "Why per-endpoint instead of global?" | "Global hides regressions when endpoints have different criticality" | "Easier to manage" |
| "How would you measure freshness?" | Names synthetic prober OR end-to-end timestamping unprompted | "Freshness?" |
| "What about CPU and memory?" | "Saturation, not SLI. Dashboard not page." | "Yes, those are important SLIs" |
| "Cache hit rate as an SLI?" | "Leading indicator — affects latency but not SLI of record" | "I'd alert on it" |

## Layer 7 — strong vs weak phrases

**STRONG**
- "Measure at the edge — closest to user experience."
- "Scope to user-facing endpoints; per-endpoint SLIs, not global."
- "Freshness is the customer-stated need — that becomes a separate SLI."
- "CPU and memory are saturation indicators, not SLIs."
- "Exclude 4xx from availability — caller errors."
- "Synthetic prober as backstop, edge as the SLI of record."

**WEAK / RED FLAG**
- "Measure inside the app." (without justifying trade-off)
- "Use CPU%." (confuses SAT with SLI)
- "Average latency." (hides p99 tail)
- "Everything that Prometheus exports." (no curation)
- Skipping freshness entirely. (didn't read the spec)

## Senior gate on Q1

Three things together:
1. Picks edge with explicit reasoning
2. Names per-endpoint scoping
3. Volunteers freshness as an SLI

3/3 = strong track. 2/3 with reasoning = hire. 1/3 = borderline. 0/3 = no hire.

---

# Q2 — The SLO (target, window, math)

## Layer 1 — what the candidate sees

> "What target(s), over what window, and why those numbers?"

Three explicit asks: target, window, justification. A senior answers **all three** — the trap is giving a target (`99.9%`) without a window or math.

## Layer 2 — plain English

"Show me the math. Don't tell me '99.9%' as if it's a round-number badge. Tell me what that number means in *minutes per month*, whether it's achievable given the failure modes in the spec, and whether the customer asked for it or you decided it."

## Layer 3 — mechanism (error budget arithmetic)

Cheat sheet every SRE memorizes:

| Target | Window | Budget per window |
|---|---|---|
| 99% | 28 days | 6 hr 43 min |
| 99.5% | 28 days | 3 hr 22 min |
| **99.9%** | 28 days | **40 min 19 sec** |
| 99.95% | 28 days | 20 min 9 sec |
| **99.99%** | 28 days | **4 min 2 sec** |
| 99.999% | 28 days | 24 sec |

Why **28 days** instead of 30: aligns with on-call rotation + matches Google SRE convention. Either window is fine; what matters is **picking one and sticking to it**.

A senior knows roughly where 99.9% lands ("about 40 min/month") and that **every additional 9 is roughly 10× harder** — 99.9% → 99.99% requires multi-region or radical architecture changes.

## Layer 4 — reality-check against the spec's failure modes

Apply the math:

| Failure | Frequency | Duration | Budget consumed |
|---|---|---|---|
| RDS failover | ~1/quarter | ~90s of 5xx | ~30s per month avg |
| Cache cold-start after deploy | Every deploy (~10/month) | 5 min × 2× p99 latency | ~50 min over month, but it's *latency degradation*, NOT 5xx — doesn't burn availability budget; DOES burn latency budget |
| Kafka outage | Rare | 0 HTTP impact | 0 (good design) |
| Bad deploy with N+1 | Occurs occasionally (~1/quarter) | ~5 min | ~1.5 min/month avg |

**Availability budget headroom for 99.9% = 40 min**:
- ~30s/month RDS = 1.25% of budget
- ~1.5 min/month bad deploys = 3.75% of budget
- Total predictable burn: ~5% of budget
- Remaining 95% absorbs unpredictable events (DDoS, AZ outage, etc.)

**Verdict**: 99.9% is realistic. 99.99% only allows 4 min/month — one RDS failover (90s) eats 38% of the budget. One bad deploy (5min) eats 125% (over). Not achievable without multi-region active-active.

A strong candidate does this math live, even rough.

## Layer 5 — what good SLO design looks like

| SLI | SLO | Window | Why |
|---|---|---|---|
| **Availability** (non-5xx at ingress) | **99.9%** | 28 days rolling | Customer said "loose 99.9%"; 40 min/month covers RDS failover + 1 bad deploy with headroom |
| **Latency** (`GET /shipments/{id}` p99) | **99% under 800ms** | 28 days rolling | Doubles current p99 (400ms) to absorb cache cold-start. Tighter would page on every deploy. |
| **Latency** (other read endpoints p99) | **99% under 600ms** | 28 days rolling | Less critical than the dominant endpoint |
| **Freshness** | **95% of new shipments visible in < 5 min** | 28 days | Customer-stated. 95% gives margin. |

`/history` has **NO SLO** — customer said they don't care. Explicit omission is a senior signal.

What matters in the candidate's answer:
1. **Per-SLI targets** (not a single global SLO)
2. **Window is explicit**
3. **Math ties to spec's known failures**
4. **They acknowledge `/history` doesn't need an SLO**

## Layer 6 — common bad answers

**"99.9% three-9s"** — no math, no window. Mid-level pattern.
**"Same SLO for all endpoints"** — ignores spec's endpoint criticality.
**"99.99% to be safe"** — shows they don't know feasibility constraints.
**"30 days"** — fine if justified; guessing if not.
**"No window — over all time"** — fundamentally misunderstands SLOs.
**Forgets freshness** — reading comprehension failure.

## Layer 7 — probes

| Probe | Strong | Weak |
|---|---|---|
| "How many minutes is 99.9% over 28 days?" | "About 40" | Doesn't know |
| "Why 28 days vs 30?" | "Aligns with on-call rotation + Google SRE convention" | Doesn't matter |
| "Can you hit 99.99% on this service?" | "Not without multi-region. One RDS failover eats 38% of budget." | "Sure" |
| "What if the SLO is too tight to hit?" | "Either invest in reliability or renegotiate target with product" | "We try harder" |
| "What if it's too loose?" | "Leaving reliability on table; tighten when budget surplus is consistent" | Doesn't see a problem |
| "Which endpoint gets the tightest latency SLO?" | "`GET /shipments/{id}` — 70% of traffic, customer-facing" | Same SLO everywhere |
| "When does 99.99% make sense?" | "Customer paying for it, or downtime cost much higher than ops cost" | "Always" |

## Layer 8 — strong vs weak phrases

**STRONG**
- "99.9% over 28 days = 40 min/month. Fits 1 RDS failover + 1 bad deploy."
- "Customer said 'loose 99.9%' — that's the floor."
- "Per-endpoint targets — global hides regressions."
- "SLO without a window is meaningless."
- "`/history` has no SLO — customer told us they don't care."
- "Going from 99.9% to 99.99% is 10× harder, not 10% harder."

**WEAK / RED FLAG**
- "Three-9s." (No math, no window.)
- "99.99% to be safe." (Ignores feasibility.)
- "30 days." (without justification)
- "Same SLO for all endpoints."
- Forgets freshness entirely.

## Senior gate on Q2

Strong candidate by this point has:
- Named 3 SLOs (availability, per-endpoint latency, freshness)
- Done rough budget math out loud
- Explicitly omitted `/history`
- Cited window choice
- Connected target choice to spec's failure modes

A candidate who's vague on math at this stage is mid at best — error budget is *the* core SRE concept.

---

# Q3 — Alert rules (multi-window burn rate, paging vs ticketing)

## Layer 1 — what the candidate sees

> "What alerts fire, at what thresholds, paging vs ticketing?"

Translate the SLO into actual alerts. Who gets woken at 3am? Who gets a ticket Monday morning?

## Layer 2 — plain English

"Do you alert against the SLO budget, or against arbitrary thresholds? Do you wake the on-call only when the user is genuinely impacted, or do you page-storm them on every transient blip?"

The senior gate is **multi-window burn-rate alerting** — a concept named in the Google SRE Workbook that most mid candidates have heard of but can't actually structure.

## Layer 3 — mechanism (multi-window burn rate)

### Naive approach (DON'T)

Single-threshold alert: "Page if 5xx rate > 1% for 5 min."

Why bad:
- 5-minute spike that recovers wakes you up
- Slow 0.5% sustained burn doesn't fire
- No relationship to SLO budget — page when you have tons of budget remaining

### Strong approach: multi-window burn rate

**Burn rate** = how fast you're consuming error budget compared to "normal."

- 1.0× = exhaust budget exactly at end of window (the "expected" rate)
- 14.4× = exhaust budget in 1/14.4 of window (~2 days for a 28-day window)

The Google SRE Workbook pattern uses TWO time windows per alert — a **long** window for accuracy and a **short** window for fast-detect. Standard recipe:

| Severity | Long window | Short window | Burn rate threshold | Triggers |
|---|---|---|---|---|
| **Page (fast burn)** | 1 hour | 5 min | 14.4× | Active fire — 2% of monthly budget in 1 hour |
| **Page (slow burn)** | 6 hours | 30 min | 6× | Sustained burn — 5% of budget in 6 hours |
| **Ticket (drift)** | 3 days | 6 hours | 1× | Consuming at expected rate; investigate non-urgently |

The double-window is key:
- **Long** window prevents flapping (transient spikes don't fire)
- **Short** window confirms problem is *still* happening (so you don't page after issue resolved)

**Why these multipliers?** For 99.9% over 28d = 40 min budget. 14.4× isn't arbitrary — calibrated so "fast burn over 1 hour" means you'd burn *entire monthly budget* in roughly 2 days if the rate continued.

### Prometheus rule shape (not exact syntax)

```yaml
- alert: AvailabilitySLOFastBurn
  expr: |
    # Long window: 1h burn rate > 14.4x
    (sum(rate(http_requests_total{code=~"5.."}[1h])) / sum(rate(http_requests_total[1h]))) > 14.4 * 0.001
    AND
    # Short window: 5m confirming
    (sum(rate(http_requests_total{code=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))) > 14.4 * 0.001
  for: 2m
  labels: { severity: page }
```

A strong candidate sketches this structure — exact PromQL not required, but articulates the AND between two windows.

## Layer 4 — applied to this service

### Availability SLO (99.9% non-5xx)
1. **Page (fast burn)**: 1h × 14.4× AND 5m × 14.4×
2. **Page (slow burn)**: 6h × 6× AND 30m × 6×
3. **Ticket (drift)**: 3d × 1× AND 6h × 1×

### Latency SLO (`GET /shipments/{id}` p99 < 800ms)
Same pattern but "error" = "request slower than 800ms". One Page-fast + one Page-slow + one Ticket-drift.

### Freshness SLO
Synthetic prober output:
- **Page**: 3 consecutive prober failures
- **Ticket**: trending degradation over 24h

### What gets TICKETED (not paged)
- **CPU > 80% sustained** → capacity ticket
- **Cache hit rate drops 10%+ from baseline** → leading indicator ticket
- **Pod restart spike** → reliability ticket
- **DB connection pool > 80%** → capacity ticket
- **Deploy events** → dashboard annotation, not alert

### What gets NO alert (operationally watched only)
- `/history` endpoint anything
- Kafka broker down (spec says HTTP unaffected)
- Memory growth within 90% of limit
- Individual 5xx spikes that recover in seconds

## Layer 5 — special considerations from the spec

### Cache cold-start after deploys (2× p99 for 5 min)
Without handling, fires latency burn alert after every deploy. Two options:
1. **Suppress alerts during deploy windows** (Prometheus `inhibit_rules` or external silencer)
2. **Calibrate burn-rate threshold** so 5 min of cold-start absorbs — but this loosens the alert generally

Strong: addresses this explicitly. Weak: ignores (gets paged Monday after Friday deploy).

### RDS failover (90s of 5xx)
- 90s × full 5xx = ~1.5 min of budget consumed
- 4% of monthly budget per failover
- If failovers are frequent, you'd see budget burn but not necessarily fast burn page
- A senior says: "Failover is a known event — runbook, not page through it. If failover takes longer than expected, then page."

### PagerDuty secondary at 5 min
Spec says "secondary fires after 5 min unacked." A senior comments positively on this. Weaker candidates don't notice the existing escalation.

## Layer 6 — common bad answers

**"Page on p99 > 500ms for 5 min"** — no SLO awareness. Mid pattern.
**"Page on every 5xx"** — page storm. Healthy services emit occasional 5xx.
**"Page on CPU > 80%"** — confuses SAT with SLI.
**"Same routes for all severities"** — on-call drowns.
**No multi-window mention** — senior gap.
**No deploy suppression for cold-start** — didn't read spec for known failures.
**Pages every alert to all 50 engineers** — bad routing hygiene.

## Layer 7 — probes

| Probe | Strong | Weak |
|---|---|---|
| "Why multi-window?" | "Catches fast burn AND slow burn without flapping" | "Better coverage" |
| "What burn rate would you page on?" | Names 14.4× / 6× or close equivalents | "Whenever it spikes" |
| "Should CPU > 80% page?" | "No — saturation, ticket" | "Yes" |
| "How keep alerts from firing on every deploy?" | "Suppress during deploy windows; multi-window absorbs 5 min" | "Just less sensitive" |
| "If PagerDuty itself is down — fallback?" | "Slack + email secondary; periodic external health-check" | "It won't" |
| "How alert on freshness?" | "Synthetic prober with consecutive-failure logic" | Doesn't know |
| "Alert vs dashboard difference?" | "Alerts demand action; dashboards inform investigation" | Treats them the same |

## Layer 8 — strong vs weak phrases

**STRONG**
- "Multi-window burn rate: fast for active fires, long for drift, double-window prevents flapping."
- "14.4× over 1 hour = 2% of monthly budget gone — page."
- "Page on user-facing signals only; ticket for SAT."
- "Suppress alerts during deploy windows to absorb cache cold-start."
- "Synthetic prober for freshness with consecutive-failure logic."
- "Per-team routing; dedup; secondary at 5 min is good design."

**WEAK / RED FLAG**
- "Page if p99 spikes." (No burn-rate awareness.)
- "Alert on CPU." (Wrong layer.)
- "Send everything to oncall."
- "Single-threshold alerts."
- Doesn't volunteer multi-window.
- Pages through RDS failovers.
- Doesn't suppress for deploys.

## Senior gate on Q3

Strong candidate:
- Names multi-window burn rate explicitly
- Cites rough numbers (14.4×, 6×, 1× or close)
- Distinguishes paging from ticketing with examples
- Addresses deploy-time cache cold-start
- Mentions at least one signal that explicitly does NOT page

Hand-wavy on the mechanism = mid at best. Multi-window burn rate is *the* core SRE alerting concept post-2018.

---

# Q4 — Error budget policy (what the team DOES when budget is consumed)

## Layer 1 — what the candidate sees

> "What does the team do when budget is 50% / 80% / 100% consumed?"

Most underweighted question in the exercise. Most candidates spend 90% of prep on SLI/SLO mechanics and 0% on what to do when burning.

## Layer 2 — plain English

"An SLO without a policy is just a number on a dashboard. What does your team actually DO when budget starts burning? Is there a *process*, or everyone-figures-it-out-in-the-moment?"

This is the negotiating-with-product part of SRE. A senior has been in the room when product asked "why are you slowing down my feature work?" — and knows the right answer is "we agreed to this policy in advance, here's the doc."

## Layer 3 — mechanism (what error budget policy IS)

### The fundamental insight

**Error budget is a tradeable currency between product and engineering.**

- Product wants velocity (more features, faster shipping)
- Engineering wants reliability (fewer outages, better quality)
- These conflict — fast shipping increases breakage risk
- The error budget says: "you have N minutes/month of failure to spend. Use it on whatever you want — risky deploys, late experiments, ambitious launches — but when it's gone, we trade velocity for reliability."

Without a policy, the "trade" never happens. With a policy, the trade is automatic — "we hit 80%, feature work pauses, that's the agreement."

### The standard tiered structure

| Consumption | Response | Who decides |
|---|---|---|
| **< 50%** | Normal operations. Budget healthy. | Team |
| **50%** | Heightened awareness. Review recent changes. Maybe slow risky deploys. | Team + tech lead |
| **80%** | **Feature freeze** — pause new feature work. Focus on reliability improvements. | Team + PM (per pre-agreed policy) |
| **100% (burned)** | **Hard freeze** — no new features. Mandatory reliability sprint. Post-mortem if exhausted from incidents. | Per pre-agreed policy; no real-time negotiation |
| **150%+ (over-burned)** | Escalate to leadership. Reliability sprint extended. Architecture review. | Engineering leadership |

### Critical nuances

**Budget freeze ≠ deploy freeze.** Bug fixes, security patches, reliability improvements still ship — they *reduce* future burn. Only NEW features pause. A senior articulates this distinction unprompted.

**Pre-agreement is the whole point.** The conversation with product happens BEFORE budget burns, not DURING.

**Budget is signal, not punishment.** Teams don't get "in trouble" for burning budget — burning budget means "we're spending the reliability we promised." The response is *prioritization*, not blame.

**Window reset rules**:
- Rolling 28-day: continuously moving window
- Calendar month: discrete; budget refills on day 1
- Quarter: longer horizon

Most teams use rolling 28-day for steady signal without the "budget refills on the 1st" gaming risk.

## Layer 4 — applied to this service

| Consumption | Policy | Specifics |
|---|---|---|
| **< 50%** (< 20 min) | Normal | Continue regular deploy cadence |
| **50-79%** (20-32 min) | Heightened review | Tech lead reviews each new feature for risk |
| **80%** (32 min) | **Feature freeze** | Pause new features. Work reliability backlog (cache cold-start mitigation, N+1 detection in CI, deploy gate). Bug fixes + security still ship. |
| **100%** (40 min burned) | **Hard freeze** | Reliability sprint. Post-mortem on what burned budget. No feature deploys until next window. |
| **Two consecutive windows over-burned** | Escalate to engineering leadership | Architecture review. Are SLOs achievable? Tech debt problem? |

A strong candidate also names **what the team should already be working on at 50%** so the response isn't a panic — a reliability backlog of pre-identified improvements.

## Layer 5 — what good answers include

Strong candidate articulates:
1. **Tiered policy** (50/80/100 or close)
2. **Pre-agreement with product** before incident
3. **Feature freeze ≠ deploy freeze** — bug fixes still ship
4. **Documented policy** — written, not interpreted
5. **Quarterly review of the policy** — based on actual burn patterns
6. **Budget as currency** — explicit language about velocity/reliability trade

Bonus signals:
- Mentions a **reliability backlog** so team has work ready
- Mentions **rolling window vs calendar window** trade-off
- Notes on-call rotation aligns with SLO window

## Layer 6 — common bad answers

**"We'd communicate to the team"** — no policy. What does the team DO?
**"Freeze all deploys at 80%"** — too blunt; stops bug fixes.
**"We try to ship less"** — vague.
**"We do a post-mortem"** — incident-driven; budget exhaustion is a process gate.
**"We tell management"** — escalation isn't a policy.
**No pre-agreement** — wrong time to negotiate.
**Treats budget burn as failure** — burning budget is *normal*.

## Layer 7 — probes

| Probe | Strong | Weak |
|---|---|---|
| "What's the POINT of an error budget?" | "Tradeable currency between product and engineering" | "To measure SLO" |
| "Who decides the tier response?" | "Pre-agreed with product before any incident" | "I do, in the moment" |
| "Budget freeze vs deploy freeze?" | "Feature freeze; bug fixes ship" | Treats them the same |
| "When does the budget reset?" | "End of SLO window — rolling or calendar" | Doesn't know |
| "What should team be doing at 50%?" | "Working from a reliability backlog so freeze isn't panic" | "Continue as normal" |
| "Burn 100% in week 1 of a 28d window — then what?" | "Reliability sprint immediately; possibly extend if pattern repeats" | "Wait until day 28" |
| "How tell product 'feature freeze' without a fight?" | "Show the pre-agreed policy doc + burn data" | "Hope they listen" |
| "Quarterly review — what would you change?" | "Adjust thresholds based on actual burn patterns" | "Doesn't change" |

## Layer 8 — strong vs weak phrases

**STRONG**
- "Tiered policy: 50% notify, 80% feature freeze, 100% hard stop."
- "Pre-agreed with product — not negotiated during incidents."
- "Budget freeze is feature freeze; bug fixes and security still ship."
- "Error budget is tradeable currency between product and engineering."
- "Reliability backlog so freeze isn't a panic."
- "Quarterly review — adjust thresholds based on actual burn."
- "Budget is signal, not punishment."

**WEAK / RED FLAG**
- "We'd communicate." (No policy.)
- "Freeze all deploys at 80%." (Too blunt.)
- Doesn't mention pre-agreement with product.
- "We'd do a post-mortem." (Confuses incident response with policy gate.)
- "Hope it doesn't happen."

## Senior gate on Q4

Strong candidate by this point:
- Named tiered policy with specific actions per tier
- Explicitly said "pre-agreed with product"
- Distinguished feature freeze from deploy freeze
- Mentioned reliability backlog as safety valve
- Articulated error budget as velocity/reliability trade

This is the question that separates "senior SRE who has lived this" from "candidate who memorized SRE Workbook chapter titles." Lived experience shows up in nuance:
- They volunteer feature/deploy freeze distinction
- They talk about the politics of getting product to agree
- They mention what teams actually DO during a freeze (work the backlog)

A candidate who says all the right phrases but can't talk about lived experience is mid. A candidate who tells you about a time their team hit 80% and what they did is senior.

---

# Q5 — What NOT to alert on (the prioritization gate)

## Layer 1 — what the candidate sees

> "What would you explicitly de-prioritize?"

Shortest sub-question. Also the one that exposes whether a candidate can **cut** things, not just add them.

## Layer 2 — plain English

"Most teams have alert sprawl — hundreds of rules, half of them noise, real signals lost in the storm. Show me you'll *intentionally* leave things out, and explain why."

The senior signal is **proactive prioritization without prompting**. A junior adds alerts to feel safe. A senior cuts alerts to keep on-call usable.

## Layer 3 — mechanism (why cutting matters)

Google SRE Book has a name: **alert fatigue**. The chain:

1. Team adds alerts "just in case I might miss something"
2. Volume climbs (50, 100, 200 per week)
3. On-call learns to dismiss most without reading
4. Real one fires → gets dismissed too
5. Outage extends because nobody acted

The economics: **every alert has a cost** — cognitive load of triaging, disruption at 3am, slow erosion of trust in the system. An alert not worth its cost is *worse than no alert at all*.

The corollary: **the *act* of removing an alert is a signal that you value on-call sleep and team trust over personal coverage anxiety.**

## Layer 4 — what the candidate should cut for this service

A strong candidate volunteers these without prompting:

### Endpoint-level cuts

**`/history` endpoint anything** — customer explicitly said they don't care if `/history` is slow. So:
- No latency alert on `/history`
- No availability alert on `/history` (it can still 5xx; dashboard, don't page)

A senior pulls this directly from the spec without being told.

### Dependency-level cuts

**Kafka broker outages** — spec says "Kafka broker outage → 0 HTTP impact." So:
- No HTTP-impact alert tied to Kafka health
- Kafka itself can have its own SLOs, but those are out of scope for this exercise

If a candidate says "page on Kafka down" — they didn't read the spec or don't trust the architectural decoupling. Both are bad signals.

### Saturation-level cuts (move to dashboards/tickets, not pages)

- **CPU > 80%** — saturation, leading indicator, ticket
- **Memory > 90% of limit** — capacity ticket
- **Pod restart count** — internal cluster behavior, unless rate-spike
- **DB connection pool > 70%** — leading indicator
- **Cache hit rate dropping 10%** — leading indicator (will eventually show in latency SLO)

The principle: **"Saturation belongs on dashboards; SLI burn belongs in alerts."**

### Operational-level cuts

- **Deploy events** → dashboard annotations
- **Renovate/Dependabot PR opened** → notification, not alert
- **Image build success rate** → CI dashboard
- **Pod scheduler latency** → cluster-level dashboard
- **Sidecar memory** → dashboard
- **Log volume spikes** → log-analytics dashboard

### Within-tolerance cuts

- **Single 5xx blip that recovers in seconds** → multi-window burn rate filters naturally
- **Cold-start latency for first 60s after a deploy** → expected, suppress
- **One pod OOMKilled then rescheduled** → cluster's job

## Layer 5 — the structural insight a senior should mention

The synthesis a strong candidate offers:

**"Alerts answer 'wake someone up.' Dashboards answer 'help me investigate.' Tickets answer 'put this in the backlog.' Each signal belongs to exactly one of those categories — and most signals belong on dashboards or in tickets, not alerts."**

A candidate who can say this in their own words is showing they've internalized the **three-tier signal hierarchy**. That's senior.

## Layer 6 — common bad answers

**"Alert on everything just in case"** — fatigue path. Will bury on-call.
**"I don't see anything I'd cut"** — no prioritization sense.
**"Maybe cut the noisy ones"** — vague.
**"Page on Kafka"** — didn't read spec.
**"Page on `/history`"** — didn't read spec.
**"Page on CPU"** — confused SAT with SLI.
**"Cut latency tracking on `/history`"** but doesn't volunteer the others — only got the gimme.

## Layer 7 — probes

| Probe | Strong | Weak |
|---|---|---|
| "Why de-prioritize `/history`?" | "Customer told us they don't care" | "Sure, why not" |
| "Cost of alerting on everything?" | "Volume erodes signal; real alerts get dismissed" | "Coverage" |
| "Where does CPU go?" | "Dashboard, not page" | "Page" |
| "Kafka broker down — page?" | "No — HTTP unaffected per spec" | "Yes" |
| "Pod restart spike?" | "Deploy regression dashboard or ticket; not page unless tied to user impact" | "Page" |
| "Three-tier signals?" | "Alerts wake people; dashboards investigate; tickets backlog" | Treats them all the same |

## Layer 8 — strong vs weak phrases

**STRONG**
- "Customer told us `/history` doesn't matter — explicit cut."
- "Saturation belongs on dashboards, not pages."
- "Alert fatigue means real ones get missed — cutting is a feature."
- "Kafka outage doesn't page if HTTP isn't impacted (spec confirmed)."
- "Alerts wake people; dashboards investigate; tickets backlog."
- "Cold-start latency for the first 60s after deploys gets suppressed."

**WEAK / RED FLAG**
- "Alert on everything in case." (Fatigue path.)
- "I don't see anything to cut." (No prioritization muscle.)
- Pages CPU / memory / Kafka. (Didn't read spec; doesn't know SAT vs SLI.)
- Vague answers without naming specific signals.

## Senior gate on Q5

Strong candidate:
- Cut `/history` unprompted (gimme — pull from spec)
- Cut Kafka unprompted (spec-reading)
- Cut CPU/memory to dashboards (SAT vs SLI)
- Named the three-tier hierarchy
- Mentioned alert fatigue as the cost

Minimum bar: 3 of 5 cuts named without prompting. Below that, not internalizing prioritization as a senior skill.

---

# The synthesis question (optional close)

After Q5, ask:

> "If you were on-call covering this service tonight and got paged at 3am, what would the alert tell you, and what would you do first?"

This is the **synthesis test**. Pulls together SLI choice, alert design, error budget policy, runbook readiness. Strong candidates name:

1. **What the alert SAYS** — which SLI burned (availability vs latency vs freshness), which endpoint, current burn rate, time window — specific not generic
2. **What runbook they'd open** — per-alert runbook is good practice; "I'd open the runbook" without specifics is mid
3. **First diagnostic step** — check recent deploys, check RDS health, check cache hit rate, sample error logs
4. **When they'd escalate** — secondary at 5 min; if recovery > 15 min, escalate to manager; if customer-impacting > 30 min, status page update
5. **What they'd add to the post-mortem** — "what changed? what was the customer impact? what would have caught this earlier?"

A senior frames this as a *practiced response*, not a *first-time exploration*. They've been on-call for real.

**STRONG synthesis answer:**
> "The fast-burn page tells me which endpoint and the current rate. I'd open the per-alert runbook — for availability burn, that means: check the deploy timeline (rollback if a deploy happened in the last hour and burn started after), check RDS for failover events, sample recent error logs. If recovery's not in sight by 15 minutes I escalate to my manager; if it's customer-impacting at 30 I update the status page. After resolution, post-mortem captures what changed, what the customer impact was, and what dashboard or alert would have caught this earlier."

**WEAK:**
> "I'd open the dashboard and see what's wrong."

---

# What to do during the exercise

## Open with

> "Walk me through SLOs and alerting for `shipment-tracking-api`. Read the spec, then in about 10 minutes propose SLIs, SLOs, alert rules, error-budget policy, and what you'd explicitly NOT alert on. Expect me to probe edges and what-ifs."

## While they work

- **First minute**: are they asking clarifying questions about traffic, customer expectations, on-call rotation? Good signal.
- **SLI choice**: are they measuring at the edge? Justifying why? If they jump to in-app metrics without rationale, probe.
- **SLO math**: do they show the math? "99.9%" without "= 40 min/month" is weaker.
- **Multi-window burn**: senior gate for alerting. If they don't volunteer it, ask: "How do you keep this from waking you up on every transient blip?"
- **Error budget policy**: weak candidates skip this entirely. Strong candidates have a tiered framework ready.
- **What NOT to alert**: strong candidates volunteer `/history` cut without prompting.

## Probes during

Don't wait until the end. Inject:
- "What's the customer cost if you're wrong about freshness?"
- "If your cache hit rate drops from 85% to 60%, does that hit your SLO?"
- "RDS failover happens — does your SLO accommodate that?"

These force them to connect SLO design to operational reality.

## Scoring rubric

| Tier | Signal |
|---|---|
| **STRONG hire** | Edge measurement w/ rationale. Volunteers freshness SLI. Budget math live (40 min/month). Multi-window burn rate by name (14.4× / 6× / 1×). Tiered error-budget policy, pre-agreed with product. Volunteers `/history` + Kafka cuts. Three-tier signal hierarchy. Synthesis answer is timeline-aware. |
| **Hire** | Edge measurement. Sensible SLOs with some math. Burn-rate awareness even if not multi-window. Error budget policy at least mentioned. Most "cut" answers surface with mild prompting. |
| **Borderline** | SLI choice mechanical (no rationale). SLO target without math. Single-threshold alerts. No error budget policy. Skips freshness. Cuts only `/history`. |
| **No hire** | "Page on CPU." "99.9% three 9s." No window. No budget policy. No prioritization. "Alert on everything." Doesn't read the spec. |

## Time budget

- ~10 min total
- 1-2 min reading the spec
- 7-8 min discussion across all 5 sub-questions
- Move on if they're flailing; depth beats coverage
