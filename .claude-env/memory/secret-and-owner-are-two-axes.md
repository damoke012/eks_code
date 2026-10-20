---
name: secret-and-owner-are-two-axes
description: "When someone asks where their env vars go, answer on two independent axes — who owns the key and whether it is a secret; a three-section ownership split always strands keys because the two axes cross"
metadata:
  type: feedback
---

**2026-10-08, Tim's RisingWave `.env`.** He proposed splitting his 75 keys three ways —
Docker-local, platform, developer. Good instinct, one axis. Secret-ness is a **second,
independent** axis, and his own file proves they cross: `POSTGRES_CDC_PASSWORD` is
developer-owned **and** secret; `KAFKA_BOOTSTRAP_SERVER` is platform-owned **and** not.

|  | non-secret | secret |
|---|---|---|
| **platform** | ConfigMap, we own the PR | Secrets Manager, we write the value |
| **developer** | ConfigMap, they own the PR | Secrets Manager, they give **key names**, we write it once |

**How to apply.** Make the grid first, then sort. Four cells, every key in exactly one. Two
rules fall out of it for free: a key's **owner** decides who raises the PR, and its
**secret-ness** decides the destination — so "platform owns it" never means "we hold the
value", and "developer owns it" never means "it goes in Git".

**Three sorting rules that caught real keys:**

1. A connection string is **not one key** — `POSTGRES_ENTITY_URL` carries host, port, db *and*
   password. Split it, or the password rides into Git inside a value labelled config.
2. A username is not automatically non-secret. For Postgres it is coordinates; for Confluent,
   `KAFKA_SASL_USERNAME` **is the API key**.
3. Image version pins have no cell at all. They are docker-compose state; in the cluster the
   version is pinned by digest in the overlay.

**Ask for key names, never values.** A value pasted into Teams or a PR is in a system we do
not control. The key list is also what makes the sort possible before anyone handles a
credential.

Related: [[eso-writes-partial-secrets]] (why the key list must be *complete* before the first
deploy), [[pod-env-secret-resolution]], [[rw-database-is-named-dev-everywhere]].

## 2026-10-08 later — the model held, and the ask leaked anyway

Tim returned the file split three ways. The ownership groups were right and **the platform
group mixed secret with non-secret**, exactly as the two axes predict. So the grid is the
correction to make the moment someone proposes an ownership-only split.

**But values came back where key names were asked for** — live Confluent SASL and
schema-registry credentials, in plaintext, by email. They were copies of the per-account
masters, so the disclosure reached every consumer of those masters, not just his file.

**How to apply:** when asking for key names, say *why* in the same breath — "names only, a
value in an email is in a system we don't control, and if it is a copy of a shared master it
is everyone's problem." A bare "send me the key names" reads as a format preference and gets
helpfully over-delivered. And on the destination side the rule has to be stated too: a Helm
`values-<env>.yaml` is Git exactly like a kustomize overlay was, so the Helm move does not
create a safe place to put a value.

Related: [[ccloud-registry-master-per-account]] — a credential that is a copy of an
account-level master has no blast radius of one.

## 2026-10-20 — the grid is now the agreed intake, and the developer is the approver

The pricing-app onboarding call landed on exactly this model without being shown it. Idris:
*"maybe the developer can go into the project variables, just list all the variables — not the
credential, just the name of the variable — and categorize which are sensitive, which are
non-sensitive. That way we know what to create in Secrets Manager, and all the non-sensitive
can go through the code change"* — i.e. `values.yaml` / the Helm chart. Matt agreed to produce
it.

**Two things to carry forward:**

1. **The application developer approves the classification; the platform only proposes.**
   Doke: *"the application developer that understands the in and out of the application is the
   one that approves and says, okay, yes, I'm comfortable with this. We can only propose at the
   end of the day."* A split recorded without that approval is an unsigned change to someone
   else's app.
2. **"Names only" was asked for correctly this time and it still needs the reason attached.**
   It worked here because Idris said *why* in the same breath ("not the credential, just the
   name").

⚠️ For a DX-deployed app the inventory has **two sources and they disagree** — see
[[app-config-source-is-octopus-not-compose]]. And the non-sensitive side is not only
application config: the **OTEL endpoint variables** Octopus injects live there, and losing
them silently kills logging ([[observability-parity-is-clickhouse-not-loki]]).

One argument for the new path worth making out loud: **Octopus sensitive variables can print
into a deploy log** (Matt's own words). Secrets Manager + ESO is plainly better, and he wants
it.
