# Senior Platform Engineer (Vibin backfill) — recruiter screen review

**Source:** 4 recruiter screens by Mariddy Sanchez. **Caveat:** all four transcripts are partial — Leo's and
Marcus's openings are missing and Justin's is truncated — so absence of an answer often means *the question
wasn't asked*, not that the candidate failed it. Judgements below are drawn only from what was said.

**Role bar (from the recruiter's own framing):** senior platform engineer, hybrid infrastructure, "extremely
code savvy, especially with Golang", IaC-heavy, Kubernetes at scale, developer experience and speed to
market, collaborating with IT architects and the director of infrastructure.

---

## Scorecard

| | Leo Martin | Marcus Sanchez | Jonathon Leach | Justin Baacke |
|---|---|---|---|---|
| Concrete scale numbers | none given | partial (declined counts) | given but **inconsistent** | **strong** (25–38 accts, ~43 clusters) |
| Shipped platform artifact | generic | **strong** (VPN + break-glass, 100–300 users) | partial (PV backup, bash/Python) | **strong** (named tool, Homebrew-distributed) |
| Golang | **not mentioned at all** | partial (Go + Python scripts) | claims GH Action in Go | none (Python) |
| Hybrid / on-prem | none | multi-cloud AWS+GCP | **claims Talos + hybrid** | none mentioned |
| IaC / GitOps | partial | strong | strong | strong |
| ADR/design authorship | "didn't call them ADRs" | mostly *reviewed*, not authored | **2 named ADRs** | mostly *contributed*, SLO/SLA |
| Trade-off reasoning | textbook, thin example | good | *not asked* | **strong** (Datadog vs New Relic) |
| Understands USX | accurate | accurate | *not asked* | ❌ **described Platform Science** |
| Comp / start | 120–150 / immediate | not asked / 2 wks | ~130–150 / 2 wks | 135–140 / 2 wks |

---

## Recommendations

### ADVANCE — Justin Baacke
**Strongest concrete evidence.** AWS Organizations landing zone at 25–38 accounts, ~43 clusters split
EKS/ECS; a named internal tool ("Pi") solving multi-account console access, written in Python, shipped with a
Firefox container-colour extension and **published to Homebrew for the team**. That last detail is the single
most credible DX signal across all four — packaging and distribution is where most "internal tool" claims
fall apart. Trade-off answer (Datadog vs New Relic, decided on Terraform provider/module fit with an existing
Terraform shop) is real reasoning, not a framework recital.

**Must probe:** he answered "what do you think US Express is?" by describing **Platform Science**. Either he
confused two logistics companies he's interviewing with, or he didn't research us. Ask directly — the answer
matters more than the slip. Also **no Golang**, and no on-prem/bare-metal exposure.

### ADVANCE — Marcus Sanchez
**Best end-to-end ownership story.** Architected and shipped an internal VPN platform used by 100–300 people
— chose the instance model, designed DR, deployed it, then productised it to a one-click experience. The
**break-glass role** design (developers self-recover when the VPN is down, instead of a handful of people
holding super-privilege) shows he thinks about failure modes and blast radius, which is exactly the muscle
this team needs. Mentions Go and Python for automation. Uniquely among the four, his trade-off answer
included the *team's* learning curve as a decision input.

**Must probe:** he declined to give AWS account counts citing "security boundaries" — reasonable, but push
for shape (order of magnitude, cluster count, on-call size). His ADR answer describes *reviewing* designs and
"providing recommendations" more than authoring them. And "multi-cloud" ≠ hybrid: no on-prem.

### ADVANCE WITH A TECHNICAL SCREEN FIRST — Jonathon Leach
The only candidate touching **Talos** — directly relevant, since our on-prem clusters run it — plus the only
one claiming a GitHub Action written in **Golang**, and he named two real ADRs (Talos adoption, multi-cluster
Argo CD). He also asked the sharpest questions of anyone: new role or backfill, why did the incumbent leave,
how is the team structured.

**But the numbers do not survive arithmetic.** "10 AWS accounts... 12 to 20 Kubernetes clusters for each
account" implies 120–200 clusters, yet he then describes ~150 nodes and 400–500 pods *in total*. Those are
irreconcilable. And "switching to **Talos Linux for our EKS nodes**" is a category error — Talos is a
standalone Kubernetes OS, not an EKS node AMI. Both could be nerves or sloppy phrasing over a real
foundation; neither should be waved through. **Verify before investing a panel's time.**

### DECLINE — Leo Martin
Polished, fluent, and almost entirely content-free. Asked what he authored and shipped, he produced no
artifact name, no user count, no scale, no repo, no outcome — only a description of what a deployment
framework *is*. Every other candidate answering the same question named something specific. **Golang is never
mentioned once**, against a role that calls it out explicitly. The trade-off answer is a well-rehearsed
recital of dimensions (reliability, cost, security, operational complexity) with one thin example. His comp
ask (120–150) also runs past the top of the posted band (105–140).

Fair caveat: his transcript is missing its first 17 minutes, so he may have given specifics earlier. If the
recruiter's notes show concrete scale evidence, revisit — otherwise this is the clear pass.

---

## Cross-cutting issues worth fixing before the next round

**1. Nobody demonstrated Golang.** The screen sells "extremely code savvy, especially with Golang" and not
one of the four evidenced it beyond a passing mention. Either the technical round must test Go directly, or
the requirement is aspirational and the JD should say so — otherwise we'll keep screening in candidates who
fail the bar we claim to have.

**2. Nobody was asked about on-prem or bare-metal.** Our hybrid story is Talos on vSphere alongside EKS, and
that is the genuinely hard part of this job. "Hybrid cloud" in the screen is being interpreted as multi-cloud
by candidates. Add an explicit question.

**3. The screens weren't consistent.** Jonathon was never asked the trade-off or the company question; Marcus
was never asked salary; Leo's scale question doesn't appear. That makes side-by-side comparison unreliable —
worth giving Mariddy a fixed question set so the next batch is comparable.

**4. Suggested technical round.** Use real material rather than puzzles — e.g. hand them the Orders/Atlas
incident from 2026-07-30 (`wip/incidents/`) with the logs and ask them to work it. It tests exactly what the
job needs: reading evidence, forming and discarding hypotheses, knowing when a measurement is lying. A
candidate who asks "what's the actual error text?" before theorising has already outperformed most of a day's
work.
