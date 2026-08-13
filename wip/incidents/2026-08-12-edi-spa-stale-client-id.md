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

## The redeploy didn't work — and that revealed the actual root cause

Giovanni redeployed at 14:27. Octopus reported Success in 4 minutes. Nothing changed:

```
ConfigMap:   09df24f3…   unchanged
ReplicaSet:  746ccc8ccd  same hash — nothing rolled
Entra:       no activity that day
```

**Because the ConfigMap is generated from an Octopus project variable that is maintained by hand.**
`ui.yaml` has `VITE_AUTH_CLIENT_ID: '#{VITE_AUTH_CLIENT_ID}'`, and `Projects-9242`'s variables held:

```
VITE_AUTH_CLIENT_ID   09df24f3-…   development
VITE_AUTH_CLIENT_ID   09df24f3-…   qa          ← identical, which cannot be correct
```

Dev and QA have different registrations (`9fba6c78…`, `d099089a…`), so this had been wrong since it
was first typed in. It only became visible when QA's registration was recreated on 10 August.
Nothing derives it from Terraform, so **no redeploy could ever have fixed it.**

`customer-profile-ui` and `xra-ui` matched their registrations — not because they're wired
correctly, but because theirs have never been recreated.

## Fix

1. Correct `VITE_AUTH_CLIENT_ID` in Octopus, per environment (done 2026-08-12).
2. **Create a new release** — Octopus snapshots variables at release creation, so re-deploying the
   existing release replays the old value and goes green having changed nothing.
3. Verify a **new ReplicaSet** and the corrected ID in the ConfigMap.
4. Test by signing in via the browser in a private window — not Postman.

`rollout restart` does not work either: the wrong value is persisted, not in memory.

## Status as of 2026-08-13 — variable fixed, still not deployed

Verified from four independent sources:

| Source | Value |
|---|---|
| Entra live `dx-qa-usxpress-edi-management-ui` | `d099089a…` ✅ |
| Octopus variable, qa scope (`Environments-941`) | `d099089a…` ✅ |
| Release `97125` variable snapshot (assembled 08-10T17:41) | `09df24f3…` ❌ |
| QA cluster ConfigMap | `09df24f3…` ❌ |

Dev is now correctly scoped separately (`9fba6c78…`), so the shared-value defect is fixed.

**No release has been assembled since 2026-08-10T17:41.** Every deployment since — including
Giovanni's on 08-12 at 20:27 — replayed `Releases-97125` and its frozen snapshot. ReplicaSet
`746ccc8ccd` has been unchanged since 2026-08-10T18:07:46Z.

The team asked for the old client ID so they could "set it back and retry". **QA is already
running the old ID** — it never changed — which is itself the proof that reverting cannot help.
`09df24f3…` returns `Request_ResourceNotFound` from Graph; Microsoft deleted it on 10 August.

Remaining action: ⋮ → **Update Variables** on `Releases-97125`, deploy to qa. Proof = new
ReplicaSet hash + `d099089a…` in the ConfigMap.

## Also found — dev EDI points at QA for everything except auth

```
VITE_API_GATEWAY                 dev + qa   https://api.edi.qa.usxpress.io/v1/
VITE_TASK_API_SCOPES             dev + qa   28af4f9d-…/.default        ← QA's edi-api
VITE_COMMITMENTS_API_BASE_URL    dev, qa    both → …qa.usxpress.io
VITE_CONFIG_EDI_AUTO_ACCEPTANCE… dev, qa    both → …qa.usxpress.io
VITE_API_BASE_URL                ALL        …/EnterpriseWebAPI_QA/api
```

Only `VITE_AUTH_CLIENT_ID` and `VITE_ENV` are genuinely per-environment. Dev testing therefore
exercises QA's APIs and QA's data. May be deliberate if dev has no EDI backends — needs confirming
with the team, and is a separate class of problem from the client-ID defect.

## Follow-up

1. **Bug — SPA client IDs are hand-maintained.** Service-to-service scopes are generated from
   Terraform (`AUTH__ApiAppScopes__*`); SPA `VITE_AUTH_CLIENT_ID` is not. Any app-registration
   recreation therefore breaks a SPA silently and permanently, and no redeploy recovers it.
   **This is the durable fix.**
2. **`VITE_TASK_API_SCOPES` is also wrong** — `28af4f9d…` is QA's `edi-api`, scoped to *both*
   development and qa, so dev points at QA's API identity.
3. Check dev — its UI was recreated the same afternoon (17:56 UTC).
4. Audit the other SPAs' Octopus variables before their registrations get recreated.

## Lesson

Match the test to the app's actual auth flow. A SPA and a service use different grant types, and a
`client_credentials` failure tells you nothing about a SPA. See
[SOP-spa-auth-client-id](../../docs/runbooks/SOP-spa-auth-client-id.md).

Related: [2026-08-10 prod orders-api outage](../../.claude/skills/prod-auth-triage/SKILL.md) — same
root behaviour (clean release recreates the registration), different failure mode.
