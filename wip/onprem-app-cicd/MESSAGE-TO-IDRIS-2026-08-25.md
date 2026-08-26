# Message to Idris — 2026-08-25

Ready to send as-is (email or Slack). Written from Doke.

---

**Subject: Cleared six tickets off your board — and Argo CD SSO is live**

Idris,

I went through your board today and closed six things. Each has a comment explaining why,
so you can push back on any of them — none of this is meant to happen behind you.

**Closed because the platform now does it:**

- **INFRA-1591** (Platform SSO via Entra). The reusable pattern was the actual goal of that
  ticket, and it shipped today as Entra OIDC on Argo CD across all three clusters — no Dex
  at all, so it generalises to any app. Your half, RisingWave as first consumer, you
  delivered back on 13 August.
- **INFRA-1488** (app-managed secrets pattern). The secrets half is done as a platform
  capability: External Secrets Operator, a ClusterSecretStore on every cluster, per-env
  Secrets Manager paths, and the ownership line written down — platform owns secret
  *delivery*, you own the *values*. The RW/postgres user-creation half moved to INFRA-1664
  rather than being dropped.
- **INFRA-1626** (get access to the Talos config). That access exists now — the talosconfig
  is in Secrets Manager and a script rebuilds a working kubeconfig from it. Proven against
  13 prod nodes this afternoon.

**Closed because the design changed underneath them:**

- **INFRA-1489** and **INFRA-1490**. Both gate the in-cluster ARC-runner pipeline design.
  The on-prem standard is now build once on GitHub-hosted runners → push to ECR by digest →
  Argo CD applies from your repo's `deploy/` overlays. Signing off a design we're not going
  to run isn't worth your afternoon. What happens to the existing dev pipeline is a real
  decision and it's on INFRA-1664.

**Moved rather than closed:**

- **INFRA-1628** (Talos + Kubernetes upgrade) → **INFRA-1664**, mine. Your 4 August ladder
  stands as the plan and the history stays the reference. It's moving because it's platform
  work and you're on the application side now, not because of anything about the work.

---

**One finding from the SSO work that you should check on the RisingWave console.**

This tenant does **not** emit a `groups` claim to the confidential (web) OIDC flow. We
verified that against every setting there is — `SecurityGroup`, `ApplicationGroup`, `groups`
present in `optionalClaims.idToken`, no claims-mapping policy, 42 groups so nowhere near the
overage threshold, `emit_as_roles` not set. It *does* emit groups to the public-client PKCE
flow, for the same user in the same minute. So the behaviour depends on the flow, not on
configuration, and that took most of a day to establish.

If the console's Dex config authorises on group membership, it's either not really doing
group-based authz or it's resting on something that won't hold. The way around it is an
Entra **app role** and the `roles` claim — issued from appRoleAssignments on the service
principal, and it works in both flows. Happy to walk through it.

---

**What's new that helps you**

Argo CD SSO is live on all three clusters. You already hold the `app-viewer` role, so just
sign in:

- https://argocd.op-qa.usxpress.io ← the only one with a real Application to look at
- https://argocd.op-dev.usxpress.io
- https://argocd.op-prod.usxpress.io

You get read access to the `apps` project — Applications, resource trees, and the sync-hook
Job's logs, which is the day-to-day value. Sync on dev and QA, **no sync on prod**: promotion
there is human-initiated by the platform, by design.

The CLI works too:

```
argocd login argocd.op-qa.usxpress.io --sso --grpc-web --sso-launch-browser=false
argocd app list
```

`--grpc-web` is required (TLS terminates at the Istio gateway) and
`--sso-launch-browser=false` is for WSL, which has no `xdg-open`.

Also: **op-prod's ingress works for the first time** since that cluster came up 27 days ago.
Its Gateway had been serving QA's hostnames, the wildcard certificate had never issued, and
the ACME solver only matched QA's DNS zone. All fixed today.

---

**On ECR — the two things you asked about**

The repository and the GitHub OIDC push role for `risingwave/etl-pipeline` **both already
exist**. You don't create either:

```
064859874041.dkr.ecr.us-east-2.amazonaws.com/risingwave/etl-pipeline
```

Two things worth knowing before you hit them:

1. **The push role is tied to one repository ARN.** If you containerise the RisingWave
   workload itself — a different image from the ETL pipeline — that needs its own repository
   and a widened role. Ask me; it isn't self-serve.
2. **Push and pull are authorised by completely different mechanisms.** Push goes through the
   OIDC role, which lives in the registry's own account, so IAM alone covers it. **Pull is
   authorised per repository** — a new repo with no policy is unreadable from every cluster
   account, and the kubelet reports `403 Forbidden`, which reads exactly like a broken pull
   secret. It isn't. If you see a 403 on a pull, ask me about the repository policy before
   touching anything else. This cost us a full sync on 20 August.

Also: the OIDC trust matches the branch **exactly**, and these repos use `master`, not `main`.

---

**Your queue, in order**

I filed the ones that were missing. Priority is in the titles because Jira priority fields
drift and a number in the summary doesn't.

| | | |
|---|---|---|
| **0** | **INFRA-1637** | You marked it complete on the 18th. The AC has two halves though: no plaintext in any catalog table *on any cluster*, and the old key **revoked** rather than replaced. Can you confirm both? Most urgent thing open. |
| **1** | **INFRA-1665** | Containerise the RisingWave workload. Highest leverage on the whole programme, and the one thing the platform genuinely can't do for you. **Blocked on INFRA-1670** (mine) — the existing push role is bolted to `risingwave/etl-pipeline`'s ARN, so a second image needs its own repo. I'll clear that. |
| **2** | **INFRA-1666** | `deploy/` base + per-env overlays, digest-pinned. Depends on 1665. |
| **3** | **INFRA-1501** | Bring `pg-postgresql` under GitOps. Reads like tidying and isn't — it's the same instance behind the QA password drift: initdb on the 11th, secret rotated on the 12th, database never learned it, nine days silent. |
| **4** | **INFRA-1667** | The 238 SIGSEGV restarts. This gates prod, not curiosity — we don't know what fixed it, so we'd meet it again there. "Cause not established" is a legitimate answer; a silent unknown isn't. |
| **5** | **INFRA-1668** | Check whether the console's Dex config authorises on group membership. If it doesn't, close it and we're done. |
| **6** | **INFRA-1669** | Sign in to Argo CD on QA. Five minutes, and it's the acceptance criterion for INFRA-1639 — you're the first app-team member to use it, so if it's wrong you'll find it. |
| **7** | **INFRA-1500** | Small cleanup — check the unused HelmRelease is still there, then remove it. |

**INFRA-1477** (dev SQL pipelines) I've left alone deliberately — it needs re-scoping against
the standard, and that waits on the dev-pipeline decision, which is on me.

---

**Three questions only you can answer**

- Should syncing on QA be yours or ours? Prod stays manual either way.
- The 238 SIGSEGV restarts on `risingwave-meta-default-0` — something crash-looped for about
  two days in August and the fix isn't written down anywhere. Do you know what changed? I
  don't want to promote that shape to prod without knowing.
- Does RisingWave go to production at all? INFRA-1475 has been sitting in To Do since May and
  prod has no ApplicationSet yet, so it's not blocking anything — but it changes what we build.

---

**Two docs**

- How the platform is actually wired — repos, the two controllers, ECR, the traps:
  the orientation page I put together for you.
- `wip/onprem-app-cicd/ONBOARDING.md` — the app-team onboarding doc.

Worth saying plainly: **that onboarding doc has never been used by an application team.**
You're the first. If it doesn't work for you it doesn't work, so tell me what it gets wrong —
that feedback is worth more to me than the deploy is.

— Doke
