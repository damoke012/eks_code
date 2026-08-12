# EDI SPA cannot authenticate — stale client ID in ConfigMap (2026-08-12)

**Reported by:** Sumit Khanna, Giovanni Gualino · **Envs:** dev + QA (EKS) · **Prod:** not affected

## Symptom

> "The previous working credential seems to be replaced on deployment."

Users of `edi-management-ui` could not authenticate. Postman tests against `edi-api` and
`edi-tender-api` returned `AADSTS501051 — not assigned to a role`.

## Root cause

`edi-management-ui`'s ConfigMap holds a client ID that **no longer exists**.

```
ConfigMap edi-management/edi-management-ui-chart
  VITE_AUTH_CLIENT_ID = 09df24f3-2aa6-49df-97f1-2d5d6e8a0b08   ← Graph: ResourceNotFound

Live dx-qa-usxpress-edi-management-ui
                      = d099089a-516d-4ec3-9fe0-ad5fb214eb1b
```

The app registration was destroyed and recreated on **2026-08-10 18:02 UTC** by
`DX-Terraform-App-Creator`. That deploy updated Entra but **left the ConfigMap on the old value**,
so the frontend tells every browser to authenticate as an identity that was deleted.

## What we ruled out (all verified, all correct)

| Checked | Result |
|---|---|
| Client ID exists in Entra | ✅ current |
| API pre-authorizes the UI | ✅ all three APIs list the current UI client ID |
| Pre-auth permission IDs match live scopes | ✅ `user_impersonation` on each |
| Admin consent | ✅ `AllPrincipals` for Graph |
| Other SPAs (`customer-profile-ui`, `xra-ui`) | ✅ ConfigMaps match their registrations |

**Entra was correct throughout.** Only the app config was wrong, and only for EDI.

## The Postman test was a red herring

`ui.yaml` declares `type: spa`. A SPA uses **delegated** scopes (`user_impersonation`) via
authorization-code + PKCE — it is never assigned an **app role**. So
`grant_type=client_credentials` returns `AADSTS501051` on a perfectly healthy SPA.

That error sent everyone (including me) looking at role assignments that were never supposed to
exist.

## Fix

**Redeploy `edi-management-ui`** — re-renders the ConfigMap from the live registration.

A `rollout restart` does **not** work: the wrong value is persisted in the ConfigMap, so restarted
pods mount the same ConfigMap and read the same dead ID.

## Follow-up

1. **Bug:** a deploy can destroy an app registration and leave the SPA's ConfigMap pointing at the
   destroyed identity. `customer-profile-ui` and `xra-ui` stayed in sync, so this isn't systemic —
   worth finding what differed in the `edi-management-ui` run.
2. Check dev — its UI was recreated the same afternoon (17:56 UTC).

## Lesson

Match the test to the app's actual auth flow. A SPA and a service use different grant types, and a
`client_credentials` failure tells you nothing about a SPA. See
[SOP-spa-auth-client-id](../../docs/runbooks/SOP-spa-auth-client-id.md).

Related: [2026-08-10 prod orders-api outage](../../.claude/skills/prod-auth-triage/SKILL.md) — same
root behaviour (clean release recreates the registration), different failure mode.
