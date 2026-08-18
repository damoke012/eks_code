# Message to Tim — RisingWave pipeline promotion (draft for Idris)

Idris drafted a message to Tim on 2026-08-18 asking what pipelines exist on op-dev and
what the promotion process is. Held before sending. This document says why, and gives
him a version that reflects what we already know and what now exists.

---

## Why the original draft needed correcting

**1. It asks questions we already have answers to.** We inventoried Tim's ETL on op-dev
on 2026-08-18 (`wip/rw-etl-promotion/FINDINGS-2026-08-18.md`). Asking "are there any dev
pipelines?" tells Tim the platform team hasn't looked at its own estate — and invites a
summary he has already implicitly given us. Better to state what we found and ask him to
correct it. Same information, a quarter of his time, and it demonstrates we did the work.

**2. "Is there an existing pattern we should follow?" inverts ownership.** Deployment
mechanics are the platform's to define; that is precisely the thing we build. Asking the
app team to supply the pattern invites them to invent one, and then we inherit whatever
they invent. As of today the pattern exists and is proven on QA and prod — so this
question has an answer, and it is ours to give, not his.

**3. It omits the time-sensitive item.** The Confluent Cloud SASL credentials are stored
in `rw_catalog.rw_sources.connector_props` as `"type": "plaintext"` and are readable by
anyone with a SQL session. That needs rotating regardless of CI/CD, and it should not
wait behind a design conversation.

**4. "Manual Query that needs to be moved" is too vague to answer.** Name the objects.

**5. It frames CI/CD as a QA-specific effort.** It is a platform capability for every
on-prem app; RisingWave is the first consumer. Framing it as "for QA" invites a
QA-shaped solution that has to be redone for prod.

## What Idris can share freely

Everything below is platform-side fact, safe to send:

* `app-risingwave` namespaces exist on **op-usxpress-qa** and **op-usxpress-prod**, with
  Istio ambient, PSA `restricted`, ResourceQuota and LimitRange.
* Cross-account pull from the shared ECR registry `064859874041` is **proven working** on
  QA — a real image pulled in 3 seconds on 2026-08-18.
* Argo CD is installed on QA with an `apps` AppProject restricted to `app-*`, and an
  ApplicationSet already generating a `risingwave-etl` Application.
* Promotion is **build once, promote by digest** — the same image QA runs is the image
  prod runs. Nothing is rebuilt between environments.
* Images must be pinned by digest, not tag. Kyverno enforces this (currently Audit).

What he should NOT promise yet: a working end-to-end build. The ECR repository, the
GitHub OIDC push role, the build workflow and the deploy overlays do not exist yet. Those
are this sprint's work.

---

## Suggested message to Tim

> Hi Tim,
>
> As we bring the RisingWave QA environment up (INFRA-1624), we've built the delivery path
> that will carry your pipeline from dev into QA and then prod. Before we wire your ETL
> into it, I want to check our understanding with you rather than guess.
>
> **What we see on op-dev today.** In the `risingwave` namespace: a Kafka source reading
> from Confluent Cloud (Avro via schema registry), feeding `brand_mv_raw`, then
> `brand_mv_state` (dedupe on MAX offset), then `brand_mv_flat`. No sinks defined. The DDL
> appears to have been applied interactively — we couldn't find it in a repository.
>
> Is that the whole picture, and is `brand_mv_flat` the intended endpoint, or are sinks
> coming?
>
> **Three things only you can answer:**
> 1. Where is the canonical copy of that SQL today — a repo, a file, or the cluster itself?
> 2. Are there objects on dev that should *not* be promoted (experiments, scratch views)?
> 3. Who owns the Confluent Cloud credentials, and who can rotate them?
>
> **One item that needs attention independently of any of this.** The Confluent SASL
> username and password are stored in the source definition in plaintext — they're
> readable from `rw_catalog.rw_sources` by anyone with a SQL session on the cluster. We'd
> like to move them into AWS Secrets Manager, delivered to the cluster by External Secrets
> and referenced from the DDL via `SECRET` rather than inlined. That means rotating them,
> so we'll need to coordinate with whoever owns them.
>
> **What we're building, so you know what to expect.** Your pipeline becomes an artefact:
> the SQL is versioned in a repository, built into an image by GitHub Actions, and pushed
> to our shared registry. Argo CD deploys it to QA, and promoting to prod is a pull
> request that moves the *same* image — nothing is rebuilt between environments, so what
> passes QA is bit-for-bit what runs in prod. You'll get a view in Argo CD showing your
> deployment's status, separate from the RisingWave platform itself.
>
> We own the credentials, the namespace and the guardrails. You own the SQL and what the
> pipeline does.
>
> Happy to walk through it whenever suits — I think 20 minutes on a call would beat a
> thread.

---

## Note on the Entra secret

Separate thread in the same conversation ("do you have the new secret" / "I will generate
it in azure" / "test now with SSO"). If that secret is for the RisingWave dev
service-account SSO, it belongs to the pattern in `rw-platform-sso-entra`, not to this
work. If it is intended for **Argo CD** SSO so app teams can log in, that is a genuine
dependency of this sprint and should be tracked as one — it is the only piece of the app
delivery path that needs an Azure app registration.
