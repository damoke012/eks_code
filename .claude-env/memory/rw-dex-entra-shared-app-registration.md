---
name: rw-dex-entra-shared-app-registration
description: RisingWave's Dex SSO uses ONE Entra app registration across dev, QA and prod — only the redirect URI differs, so a new environment is a URI addition, not a new registration
metadata:
  type: project
---

`manifests/op-usxpress-dev/risingwave-console.yaml:90` and
`manifests/op-usxpress-qa/risingwave-console.yaml:78` both carry
`clientID: e112d6ce-cc60-4884-9898-8fcc5b78b0b1`, tenant
`bbb5a66d-5c9f-482a-969a-a40304b6bc8d`. Only the redirect URI differs:

    dev:   https://risingwave-dashboard.op-dev.usxpress.io/dex/callback
    qa:    https://risingwave-dashboard.op-qa.usxpress.io/dex/callback
    prod:  https://risingwave-dashboard.op-prod.usxpress.io/dex/callback  (to add)

**Why it matters:** standing up a new environment does **not** need an identity request for a
new app registration. Add the redirect URI to the existing one. And because a client secret
belongs to the registration rather than the environment, the new environment's
`<cluster>/risingwave/dex_entra_client_secret` is a **copy of QA's value**, not a new secret
to chase. This turned a multi-day external dependency into a self-service change on 2026-08-31.

**How to apply:** before raising any Entra request for an on-prem app, grep the other
clusters' manifests for `clientID` first. Two caveats, neither blocking: one registration
across all environments means one compromised secret reaches prod, and if the registration is
ever DX-managed a deploy recreates it with a new client ID and breaks all three clusters at
once — see [[dx-entra-app-recreation]]. Related: [[argocd-onprem-entra-oidc]],
[[entra-secret-rotation]], [[identity-names-do-not-cross-systems]].
