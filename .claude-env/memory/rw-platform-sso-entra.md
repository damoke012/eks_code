---
name: rw-platform-sso-entra
description: "Reusable dev service-account Entra SSO pattern (INFRA-1591); RisingWave first consumer — QA dashboard SSO wired 2026-08-13, one Entra app shared dev+QA"
metadata: 
  node_type: memory
  type: project
  originSessionId: e3125f37-c991-4364-adf2-b40770a2d61c
  modified: 2026-08-13T22:28:57.186Z
---

Workstream from the 2026-07-13 standup. RisingWave SSO needs **Entra ID (Azure)**: client
credentials, client secret, tenant ID.

**Decision:** do NOT build it one-off for RisingWave. Build a **reusable platform SSO pattern using
a dev service-account Entra app registration**, so it replicates to other apps. RisingWave is the
**first consumer**. Owner: Idris. **INFRA-1591**, under the AAD identity strategy (INFRA-1559).

## As built on op-qa (2026-08-13)

Dex is **embedded in the RisingWave console** — no separate Dex deployment. Config lives in
ConfigMap `risingwave/risingwave-console-dex`, issuer
`https://risingwave-dashboard.op-<env>.usxpress.io/dex`.

**One Entra app `risingwave` (`e112d6ce-cc60-4884-9898-8fcc5b78b0b1`) is shared by dev and QA.**
Registering QA's callback was the fix; the secret was never the problem (both credentials valid to
2028). Client secret arrives via ESO from `op-usxpress-<env>/risingwave/dex_entra_client_secret`,
property `DEX_ENTRA_CLIENT_SECRET` — so it must be stored as **JSON**, not a bare string.

**Sharp edges:** `az ad app update --web-redirect-uris` *replaces* the list (pass every env's URI);
`az ad app credential reset` without `--append` deletes all existing passwords and would take the
other environment down. `op-qa-platform-admin` has **no Secrets Manager access** to those paths —
ESO can read, humans cannot; needs adding to the permission set.

Details + open items: `wip/rw-qa-operator-split/rw-qa-dex-sso-2026-08-13.md`.

Related: [[risingwave-onprem]], [[entra-secret-rotation]], [[eso-secretsynced-not-content-check]].
