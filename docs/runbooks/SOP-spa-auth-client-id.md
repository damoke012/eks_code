# SOP — SPA users can't sign in after a deploy

**Audience:** Application teams · **Owner:** Cloud/Platform · **Version:** 1.0 (2026-08-12)

---

## Symptom

Users of a UI (SPA) can't authenticate. Often described as *"the credential that was working has
been replaced."* Usually starts right after a deploy.

---

## Step 1 — Compare the ConfigMap against the live app registration

This is almost always the answer.

```bash
kubectl -n <namespace> get cm <app>-chart -o jsonpath='{.data.VITE_AUTH_CLIENT_ID}{"\n"}'

az ad app list --all --query "[?displayName=='dx-<env>-usxpress-<app>'].appId | [0]" -o tsv
```

**If they differ, that's the fault.** The frontend is telling browsers to authenticate as an
identity that no longer exists.

Confirm the ID in the ConfigMap is genuinely dead:

```bash
az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals(appId='<id-from-configmap>')" \
  --query '{name:displayName}' -o json
```

`Request_ResourceNotFound` = confirmed.

---

## Step 2 — Fix

**Redeploy the UI through Octopus.** That re-renders the ConfigMap from the live registration.

### ⚠️ `rollout restart` does NOT fix this

The wrong value is **persisted in the ConfigMap**. Restarted pods mount the same ConfigMap and read
the same dead ID.

| Situation | Action |
|---|---|
| Config is right, process is stuck (e.g. Mongo pool paused) | `rollout restart` |
| **Config itself is wrong** (this case) | **Redeploy** |

### Do not use a Clean release

It rebuilds the app registration again, breaking anything that consumes this app. See
[SOP-mongo-connection-pool-paused](SOP-mongo-connection-pool-paused.md).

---

## ⚠️ Don't test a SPA with `client_credentials`

A SPA authenticates with **delegated** scopes (`user_impersonation`) via authorization-code + PKCE.
It is **never assigned an app role**.

So this test:

```
POST /oauth2/token   grant_type=client_credentials   resource=<api>/.default
```

returns **`AADSTS501051 — not assigned to a role`** on a **completely healthy SPA**. It proves
nothing. On 2026-08-12 it sent the whole investigation down the wrong path.

**Use the real error instead** — the failing request in the browser's network tab, or the `AADSTS`
code from the login redirect.

---

## If the ConfigMap is correct

Then it's not this. Check in order:

1. **Stale user session.** Recreating a registration creates a new service principal, invalidating
   every existing token. **Sign out, clear site storage, sign back in.** Try a private window.
2. **API pre-authorization** — the API must list the UI's *current* client ID:
   ```bash
   az rest --method GET --url "https://graph.microsoft.com/v1.0/applications(appId='<api-app-id>')" \
     --query "{name:displayName, preAuth:api.preAuthorizedApplications}" -o json
   ```
3. Escalate to Cloud/Platform with the browser error attached.

---

## Quick reference

| | |
|---|---|
| **First check** | ConfigMap `VITE_AUTH_CLIENT_ID` vs live app registration |
| **Fix** | Redeploy the UI |
| **Won't work** | `rollout restart` — the bad value is on disk, not in memory |
| **Never** | Clean release; or judging a SPA by a `client_credentials` test |

Incident: `wip/incidents/2026-08-12-edi-spa-stale-client-id.md`
