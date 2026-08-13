# BUG — three SPAs override DX's client ID with a hand-maintained Octopus variable

**Raised:** 2026-08-13 · **Severity:** High (silent auth outage, unrecoverable by redeploy)
**Component:** app-side `deploy/ui.yaml` in `edi-management-ui`, `customer-profile-ui`, `xra-ui`

> **Correction (2026-08-13):** an earlier version of this bug claimed DX does not generate the SPA
> client ID. That was wrong. DX **does** generate and publish it. Three apps override it.

---

## Summary

DX creates each SPA's Entra registration and emits its client ID as a Terraform output, then writes
it into the deploy manifest. Correctly-wired UIs declare **no auth config** and let DX supply it —
so when a registration is recreated, the new ID flows through automatically.

Three apps instead declare `VITE_AUTH_CLIENT_ID` in `ui.configVars`, sourced from a hand-maintained
Octopus project variable. That entry **overrides DX's own output**. When the registration is
recreated the app keeps announcing the deleted ID, and no redeploy recovers it.

## Proof — from the deploy that broke QA

`Deployments-130766`, QA, 2026-08-10 18:04, task log:

```
module.azure_app.azuread_application_pre_authorized.known_client_apps["dx-qa-usxpress-edi-api"]:
  Creation complete [id=901689d5-…/preAuthorizedApplication/d099089a-516d-4ec3-9fe0-ad5fb214eb1b]

Outputs: module=auth
client_id = "d099089a-516d-4ec3-9fe0-ad5fb214eb1b"

Updating manifest with output variables
```

**DX held the correct ID during that deploy.** The same log's manifest shows what won:

```json
"ui": { "configVars": { "VITE_AUTH_CLIENT_ID": "09df24f3-2aa6-49df-97f1-2d5d6e8a0b08", … } }
```

The ConfigMap was written with the dead ID, and has stayed that way since.

## The fleet splits cleanly

| Project | `VITE_AUTH_CLIENT_ID` Octopus variable | Behaviour |
|---|---|---|
| `fade-ui` | none | ✅ DX supplies it — self-heals |
| `ocs-ui` | none | ✅ |
| `pam-ui` | none | ✅ |
| `edi-management-ui` | dev, qa | ❌ overrides DX — **broken since 2026-08-10** |
| `customer-profile-ui` | dev, qa, staging, prod | ❌ latent |
| `xra-ui` | dev, qa, staging, prod | ❌ latent |

The three healthy UIs declare only API URLs in `configVars` — no client ID, no tenant ID:

```json
fade-ui  { "VITE_ALLOCATION_API": "https://api.orders.allocation.usxpress.io/v1" }
pam-ui   { "VITE_API_BASE_URL": "…", "VITE_ENVIRONMENT": "production" }
```

**`customer-profile-ui` and `xra-ui` carry the identical fault in prod.** Their values match live
registrations today only because those registrations have never been rebuilt. The first clean
release of either reproduces the EDI outage in production.

## Why services were never affected

Server-side apps read their identity from Secrets Manager via ESO, which Terraform rewrites every
deploy. There is no manifest entry to override, so the failure mode does not exist for them. That
is why prod's August 2026 clean releases (`orders-api`, `graphql-gateway`, `mosh`, `employees-api`,
`ops-drivers-api`, `io-maintenance-api`, `manhattan-dl-pipeline`) all self-healed.

## Fix

Remove `VITE_AUTH_CLIENT_ID` from `ui.configVars` in the three app repos **and** delete the matching
Octopus project variable — the two must change together, or `'#{VITE_AUTH_CLIENT_ID}'` is left
unresolved. Match `fade-ui`.

Open question: DX injects the identity under a name we have not yet identified — it is not a
GUID-shaped ConfigMap value in the healthy UIs. Confirm how those apps consume it before asking the
teams to switch, since EDI's frontend may need a small code change rather than only a config change.

## Interim

`edi-management-ui` QA is broken now. Fastest unblock is ⋮ → **Update Variables** on
`Releases-97125` then deploy — Octopus snapshots variables at release creation, so the existing
release replays the stale value otherwise. That is a workaround; the override is the defect.

## Related defect, same shape

`terraform-azuread-app/outputs.tf` emits `client_id` (changes on every recreation) rather than
`identifier_uris[0]` (`api://dx-${env}-${name}`, deterministic).

---

Related: [2026-08-12 EDI SPA incident](2026-08-12-edi-spa-stale-client-id.md) ·
[SOP-spa-auth-client-id](../../docs/runbooks/SOP-spa-auth-client-id.md)
