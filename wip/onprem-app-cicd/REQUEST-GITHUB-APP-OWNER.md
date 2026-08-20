# Request to a variant-inc org owner — a GitHub App for Argo CD (INFRA-1647)

**Why this is a request and not a task:** creating an org-owned GitHub App needs owner
rights. `dare-x` is a member (verified 2026-08-20 — `gh api orgs/variant-inc/memberships`),
so the New GitHub App page returns 404.

**Owners as of 2026-08-20:** `usx-devops`, `buddy-james`, `higdonmatthew`, `stevebduckjr`,
`svivesusx`.

---

## Suggested message

> Argo CD on the on-prem QA and prod Talos clusters currently holds **no Git credential at
> all**, so it cannot read any private or internal `variant-inc` repository. Every
> application we deliver through it fails with `ComparisonError: authentication required`.
> This blocks the on-prem app delivery path for every app, RisingWave being the first.
>
> Could one of you create an org-owned GitHub App for it? It takes about five minutes:
>
> * **Settings → Developer settings → GitHub Apps → New GitHub App**
> * Name: `argocd-onprem`
> * Homepage URL: `https://github.com/variant-inc`
> * Webhook: **untick Active** — Argo CD polls, it needs no webhook
> * Permissions → **Repository → Contents: Read-only**. Nothing else. No write anywhere,
>   no org permissions, no account permissions.
> * Where can this App be installed: **Only on this account**
> * Create, then **Generate a private key**, then **Install App** on `variant-inc` —
>   either all repositories, or just `risingwave-pipeline` to start.
>
> What I need back: the **App ID**, the **Installation ID** (the number at the end of the
> installation URL), and the **private key** `.pem`. The key should come through something
> that is not chat — I can give you an AWS Secrets Manager path to drop it in, or you can
> hand it over in person.
>
> **What it can do:** read the contents of the repositories it is installed on. Nothing
> else. It cannot write, cannot see actions or secrets, and cannot administer anything.
>
> **Why an App rather than a PAT:** the installation token is short-lived and Argo CD
> renews it itself, so there is no expiry to miss. A PAT expiring is not hypothetical
> here — the Flux Git token on the QA cluster expired on 2026-08-16 and every Kustomization
> kept reporting `Ready=True` against two-day-old config until someone noticed. An App also
> belongs to the org rather than to a person, so it survives offboarding.

---

## If the answer is slow

Ship `repo-creds-externalsecret-pat.yaml` with a fine-grained PAT to prove the delivery
path end to end, and swap when the App arrives. The swap is three keys inside the same
ExternalSecret, targeting the same Secret name — Argo CD sees a credential change, not a
credential replacement, and nothing needs to be reconfigured.

Record the PAT's expiry on INFRA-1647 the day it ships, and treat INFRA-1642's
stale-source alert as a dependency rather than parallel hygiene: with a PAT in place,
nothing on either cluster tells us when it dies.
