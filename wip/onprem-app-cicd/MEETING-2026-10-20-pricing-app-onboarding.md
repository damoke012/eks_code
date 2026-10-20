# On-prem application onboarding — first app (pricing) — 2026-10-20

Source: AI note-taker transcript of the "On-Premises Application Onboarding" call, forwarded
by email. Platform side: Dare (Doke), Idris. App side: Matt and Andres (developers),
Shrikant (manager; the transcript labels him "Mike"). **The transcript's speaker labels are
unreliable** — Dare appears as both "Daria" and "Darragh", Shrikant as "Mike"/"Sri"/"Soumya"/
"Samet". Verify any quote against a person before citing it to them.

**The app:** the pricing application, repo in `usxpressinc`, currently deployed through
Octopus/DX to EKS. Prod version **0.1.39** (recent), which is also what should go to QA. It
is an older application that "orchestrates a lot of things and just calls them" — low
horsepower, patterns from a couple of years ago, and explicitly *not* the best exemplar of
current practice.

**Why this app:** the premise of the whole engagement is that a partner endpoint (KNX
processing tools) **worked from on-prem and did not work from cloud**. Matt proved that
once, before the cloud deploy, and said so himself: *"the tests worked on-prem, but I've
slept since then as well."*

## Why the call happened

This is the **first application onboarded to on-prem through an intake process**, and the
process exists because RisingWave did not have one. Idris, verbatim: *"we did a mistake
where we onboarded RisingWave where we didn't have all these questions that have been asked
… we just went straight to onboarding. We don't want every app that we're gonna be
onboarding to just go straight to onboarding."*

So the deliverable of this engagement is **two things, not one**: the pricing app on-prem,
and the reusable intake + CI/CD path every later app uses.

## Decisions made on the call

| # | Question | Decision | Who decided |
|---|---|---|---|
| 1 | Move the app repo to `variant-inc`? | **No.** Nearly all USX repos are in `usxpressinc` and copying them is not worth the time. The platform references the repo where it lives. | Shrikant |
| 2 | CPU / memory / replicas per pod? | **Not an app-team input.** DX generates the deployment YAML; nobody on the app side sets limits. Read the settings off the live DX **production** cluster and copy them. | Andres / Shrikant |
| 3 | Which ECR repository? | **Reuse the existing one.** The app's current GitHub Actions build already pushes to ECR and Octopus pulls from there; the existing repos also carry retention policies. A second push doubles storage and splits provenance. | Andres / Shrikant, accepted by Dare |
| 4 | Where do env vars come from? | **Octopus project variables (+ what DX creates in Terraform).** `docker-compose.yml` is local development only — "almost always used for local development, never used for deployment", and the old ones may not even work. | Andres |
| 5 | Who classifies sensitive vs non-sensitive? | Platform **proposes**; the **application developer approves**. Dare: *"the application developer that understands the in and out of the application is the one that approves."* | Dare |
| 6 | What does the app team hand over? | A list of **variable names only** — no values — tagged sensitive / non-sensitive. Sensitive → Secrets Manager (ESO). Non-sensitive → `values.yaml` / the Helm chart. | Idris, agreed by Matt |
| 7 | Who owns the pipeline? | Platform. The app repo gets **our** workflow, which triggers the CI/CD pipeline held in `variant-inc`. | Dare |
| 8 | Octopus / DX future | **DX is leaving.** Octopus stays in cloud "for a very long time"; on-prem uses Octopus **only to build the cluster**, never to deploy apps. Cloud Argo CD is still POC and will not move for most of next year. | Dare |
| 9 | Observability | **Nothing changes.** Whatever the app uses today is replicated on-prem; Argo CD's per-pod log view is an addition, not the replacement. | Dare, after Shrikant's parity requirement |

## Responsibility split, as stated

**App team owns:** the application; the image ("an artifact that is the same across all
environments"); how the image is created and promoted environment to environment;
application-level alerts.

**Platform owns:** anything sensitive and anything that expires — *"comes to us, we abstract
that away from you"*; the services the app spins up (by agreement, not unilaterally);
platform events and cluster-wide issues; the CI/CD pipeline and the workflow the app repo
calls.

## The gap the call actually exposed — observability is ClickHouse, not Loki

Dare proposed Loki. Andres then shared the screen: every log query in the **Application
Monitoring** Grafana dashboard reads `otel_logs_custom`, and **there is no Loki data source**
in the USX Grafana. Shrikant: *"I believe Loki was replaced by ClickHouse."*

That matters more than the tool name:

* The app team's working pattern is **aggregated search across all pods** from one Grafana
  dashboard, plus P90/P95 metrics per dependency. Argo CD gives you **one pod at a time** —
  Andres: *"we very rarely go to the pods because then you have to click on each one."*
  Per-pod logs are **not parity**, and the call accepted parity as a requirement.
* **Octopus injects the OTEL endpoint variables** that make this work ("it injects certain
  variables to help it know where all the otel endpoints are"). Those variables are on the
  non-sensitive side of the split, and if they are missing on-prem the app runs perfectly,
  Argo CD is green, and **no log ever reaches the dashboard**. Nothing reports it. This is
  gate 5 of the delivery relay wearing a different hat.
* Neither side knows the USX log **retention** policy. Unowned.

## Open items

| # | Item | Owner | Blocking |
|---|---|---|---|
| 1 | Send the variable name list from Octopus config, tagged sensitive / non-sensitive | Matt | the whole split; everything downstream |
| 2 | Read pod CPU/memory/replicas off the DX **prod** cluster | Idris | sizing the on-prem namespace |
| 3 | Understand how DX creates this app's variables in Terraform — pull **Parul or Rohit**, ~30 min | Idris | whether a variable has a home at all |
| 4 | Ping the KNX QA endpoint **from on-prem** as a sanity check | Idris (Matt will also test) | the premise of the engagement |
| 5 | Confirm whether the KNX token is the same tenant across environments | Matt | it is currently the **same creds in test and prod** — a temporary partner-side workaround, and it will read as a platform bug |
| 6 | Confirm which log store and what retention USX actually uses | platform (cloud team) | parity claim in item 9 above |
| 7 | Decide whether the app changes to accept a whole connection string | Matt (volunteered, bandwidth permitting) | it currently assembles connections from pieces so some parts can be hidden — and Matt notes Octopus sensitive fields *"can just dump right into the log"* |

## Proven

* The intake process exists because RisingWave skipped it — stated on the call, by Idris.
* The app repo stays in `usxpressinc`; the platform adapts. Confirms the ECR-not-GitHub
  boundary already recorded in `two-orgs-join-at-ecr-not-github`.
* Deployment sizing for a DX app is **not** in the app repo and **not** known to the app
  team; it is generated by DX and visible only on the running cluster.
* `docker-compose.yml` is not a configuration source for a DX-deployed app.
* USX log aggregation is OTEL → `otel_logs_custom` (ClickHouse), read from the Application
  Monitoring dashboard. No Loki data source exists.
* The pricing app holds **SQL passwords as Octopus sensitive variables**, not in Secrets
  Manager — so for this app the secret inventory is split across two systems, and Matt
  believes the DX side may not be provisioned at all.

## Tested and killed

* **Loki as the on-prem log store, by assumption.** Killed on the call by reading the live
  dashboard's data source. Do not propose a log backend for an app before reading the query
  the app team already uses.
* **A second ECR repository for on-prem.** Killed for storage cost, retention duplication
  and split provenance. The existing repo is the one on-prem pulls.
* **Asking the app team for CPU/memory/replicas.** Killed — they do not have the answer and
  never did.
* **Moving the repo to `variant-inc`.** Killed by the app owner, not by us.

## Traps

* **The transcript is not an attribution source.** One person appears under three names.
  Verify before quoting anyone to anyone.
* **"All our variables are in Octopus" (Andres) and "we have SQL passwords in sensitive
  variables, and I'm not sure if those are provisioned on the DX side" (Matt) are both true
  and do not agree.** The inventory has two sources, and the app team's own answer depends
  on who you ask. Enumerate both; do not accept the first "that's all of them".
* **The premise is stale.** "It works on-prem" was measured once, months ago, by someone who
  says so himself. Ping the endpoint from on-prem before the migration work, not after.
* **Parity is a stated requirement now.** Shrikant: *"what I don't want to do is lose what we
  already got in cloud."* Any on-prem answer that drops aggregated log search across pods
  will be read as a regression, correctly.
* **Octopus sensitive variables can print into logs.** Moving them to Secrets Manager + ESO
  is an improvement the app team wants; say so, because it is the one place the new path is
  plainly better than the old.
* **The app developer, not the platform, is the approver of the classification.** A platform
  decision recorded without that approval is an unsigned change to someone else's app.
