# BUG — SPA client IDs are hand-maintained in Octopus, not generated from Terraform

**Raised:** 2026-08-13 · **Severity:** High (silent, unrecoverable-by-redeploy auth outage)
**Component:** DX delivery — `terraform-azuread-app` + Octopus project variables

---

## Summary

Every DX app's Entra identity is created by Terraform. For **services** the resulting client ID is
delivered automatically. For **SPAs** it is typed in by a human and never updated again.

So when a UI's app registration is recreated, the UI keeps announcing the deleted client ID.
**No redeploy, rollback or `rollout restart` recovers it.** Users cannot sign in until somebody
knows to edit an Octopus variable and cut a *new* release.

## The two delivery paths

| | Service (`-api`, `-handler`, `-cron`) | SPA (`-ui`, `type: spa`) |
|---|---|---|
| Path | Terraform → Secrets Manager → ESO → K8s Secret → `envFrom` | Octopus project variable → `#{VITE_AUTH_CLIENT_ID}` → ConfigMap |
| Written by | Terraform, every deploy | A person, once |
| After registration recreation | Next release repairs it automatically | Stale forever |

A browser cannot hold a client secret, so a SPA cannot read from the ESO-synced Secret the way a
service does. Its client ID has to arrive as plain build config — and nothing wires the
Terraform-created registration into `configVars`.

## Evidence

**QA `edi-management-ui`** — registration destroyed and recreated 2026-08-10 18:02 UTC by
`DX-Terraform-App-Creator` (clean release; task log shows `[Auth] Started Tf Destroy` at 17:59).

```
ConfigMap  VITE_AUTH_CLIENT_ID = 09df24f3-2aa6-49df-97f1-2d5d6e8a0b08   ← Graph: ResourceNotFound
Live       dx-qa-usxpress-edi-management-ui = d099089a-516d-4ec3-9fe0-ad5fb214eb1b
```

Redeployed 2026-08-12 14:27. Octopus reported Success in 4 minutes. **Nothing changed** — same
ReplicaSet `746ccc8ccd`, same dead ID. Two compounding causes:

1. The Octopus variable is hand-maintained, so a redeploy rewrites the same stale value.
2. Octopus snapshots variables at **release creation**; the release was cut at 17:41, twenty-one
   minutes before the registration was destroyed.

The dev and QA rows held the **identical** value despite having different registrations
(`9fba6c78…` vs `d099089a…`) — wrong since it was first typed, invisible until the recreation.

## Prod carries the same fault — it just hasn't been hit

Everything clean-released in prod during August 2026 was a **service**:

```
2026-08-06  employees-api        2026-08-10  graphql-gateway
2026-08-06  ops-drivers-api      2026-08-10  orders-api
2026-08-12  manhattan-dl-pipeline 2026-08-10 mosh
2026-08-12  io-maintenance-api
```

All self-healed via Terraform. **No prod UI has ever been clean-released**, which is the only
reason no prod variable has needed editing. Verified 2026-08-13 — both prod SPAs still match:

```
customer-profile-ui  ee7f1b88-f87f-429f-a0ca-4db198596c4e  ✅ matches live registration
xra-ui               20f7e6d6-382b-4cb4-a748-3c85980a54fc  ✅ matches live registration
```

The first clean release of `customer-profile-ui`, `xra-ui`, `pam-ui`, `ocs-ui`, `fade-ui`,
`spot-premium-ui`, `xpress-os-ui` or `freight-opp-ui` reproduces this exactly.

EDI itself has **no prod deployment** — no `azure-app-dx-prod-usxpress-edi-*` secret, no namespace.

## Open question — the other seven prod UIs

Nine UIs run in prod; only two carry a client ID in a ConfigMap. The other seven have Entra
registrations but no GUID-shaped config value under any key. Either:

1. it sits inside a config blob (`config.json` / `env-config.js`) — no worse than today; or
2. **it is compiled into the JS bundle at build time** — worse: recovery would need a full image
   rebuild, not a variable edit.

Settle this before sizing the fix. Command in `SOP-spa-auth-client-id.md`.

## Fix

Emit the SPA client ID from `terraform-azuread-app` and consume it the way
`AUTH__ApiAppScopes__*` already is, so `#{VITE_AUTH_CLIENT_ID}` stops being human-maintained.

**Related defect, same root cause:** `terraform-azuread-app/outputs.tf` emits `client_id` (a GUID
that changes on every recreation) instead of `identifier_uris[0]` (`api://dx-${env}-${name}`,
deterministic). Deployment-time identity leaking into config that nothing refreshes.

## Interim workaround

Any clean release of a UI requires the Octopus variable to be corrected afterwards, per
environment, followed by a **new release**. This is a workaround for a defect, not a procedure.

---

Related: [2026-08-12 EDI SPA incident](2026-08-12-edi-spa-stale-client-id.md) ·
[SOP-spa-auth-client-id](../../docs/runbooks/SOP-spa-auth-client-id.md)
