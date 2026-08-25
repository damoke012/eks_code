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
