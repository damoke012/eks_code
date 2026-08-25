---
name: argocd-onprem-entra-oidc
description: op-dev Argo CD authenticates via Entra OIDC (Dex removed); authorization blocked — Entra emits no groups claim
metadata:
  type: project
---

**op-dev Argo CD SSO, as of 2026-08-25.** Authentication **works and is proven**; authorization
does **not** — Entra issues a valid token with **no `groups` claim**, so `policy.csv` never
matches and `policy.default: ""` applies.

App `Argo CD On-Prem` **42dc0c33-4c56-47a5-b207-d119272997aa**, SP
**b20084ae-9f13-4ca7-961c-b05f023fa2c2**, tenant **bbb5a66d-5c9f-482a-969a-a40304b6bc8d**.
All three cluster callbacks registered, so **QA and prod need no Entra work** — only a branch PR.

**op-qa reached parity 2026-08-25** (PRs #135 + #136). Verified without a browser:
`curl https://argocd.op-qa.usxpress.io/` → 200, `/api/v1/settings` serves the Entra
`oidcConfig`, `argocd-entra-oidc` secret holds 40 bytes. DNS `.139 .23 .106`. Login itself
untested; the groups claim is a tenant-level question so QA's outcome would not change it.
op-prod: client secret IS stored (`op-usxpress-prod/platform/argocd/azure-ad`, us-east-2, 937464026810 — no permission-set grant needed, `ops-controller` could already write; region derived from evidence, not assumed). Branch NOT wired: no `configs.cm.url`, no `rbac` block, no Secrets Manager grant, and its
ClusterSecretStore is unverified (no persisted kubeconfig).
Argo v3.4.5. Dex deleted. Secret at `op-usxpress-dev/platform/argocd/azure-ad`
(**us-east-2**, account 700736442855, profile **`usx-dev`**), delivered by the existing
`admin-externalsecret.yaml` (`creationPolicy: Merge` into `argocd-secret`).

**Why:** Argo redeems the auth code **server-side**, so it needs a **confidential (web) client** —
an SPA registration fails at the callback with `AADSTS9002327`, which kills the
no-client-secret PKCE design. The cloud EKS fleet's own `Argo CD` app
(`56078536-…`, four `/auth/callback` URIs, two production, **zero owners**) already showed this;
never reuse that app — `--web-redirect-uris` replaces the list wholesale.

**How to apply:** killed so far — `ApplicationGroup`, `SecurityGroup`, and removing
`requestedIDTokenClaims`. Ruled out by readback — 42 security groups including the target one,
`groups` in `optionalClaims.idToken`, no claims-mapping policy, assignment present. What is left
is tenant-level (token issuance policy, Conditional Access, or the ADFS federation at
`usxfs.usxpress.com`) and needs the directory owner. Full detail:
`wip/onprem-argocd/FINDINGS-2026-08-25-entra-oidc.md`. See
[[identity-names-do-not-cross-systems]], [[adjacent-step-green-signals]],
[[argocd-sso-blocked-on-management-account]].


**op-prod blocked 2026-08-25.** No VirtualService for argocd, so the callback has nowhere to
land — and no route on that branch can be copied from, because all 5 belong to op-dev
([[manifests-copied-across-branches]]). Unblocks with INFRA-1663 (no prod kubeconfig).
