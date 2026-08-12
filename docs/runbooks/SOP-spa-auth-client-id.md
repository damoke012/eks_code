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

## Step 2 — Find the source: it is an Octopus variable, NOT the ConfigMap

**The ConfigMap is generated. Fixing it, or redeploying, will not help on its own.**

`ui.yaml` declares:

```yaml
configVars:
  VITE_AUTH_CLIENT_ID: '#{VITE_AUTH_CLIENT_ID}'
```

That `#{...}` is substituted from an **Octopus project variable that is maintained by hand**. It is
*not* generated from Terraform, so nothing updates it when an app registration is recreated. Every
deploy faithfully writes the stale value back.

```
https://octopus.usxpress.io/app#/Spaces-245/projects/<project>/variables
```

Check `VITE_AUTH_CLIENT_ID` — there is one row per environment. Compare each against its live
registration (`dx-<env>-usxpress-<app>`).

> On 2026-08-12 both dev and QA held the *same* value, which cannot be correct — the two
> environments have different registrations. It had been wrong since it was first typed in and only
> surfaced when QA's registration was recreated.

## Step 3 — Fix

1. **Correct the Octopus variable**, per environment. Save.
2. **Create a NEW release**, then deploy.

### ⚠️ Octopus snapshots variables at release creation

**Re-deploying an existing release replays the variable values from when that release was cut.** It
will go green and change nothing — same ReplicaSet, same ConfigMap. This wasted a cycle on
2026-08-12.

Either create a new release, or on the existing release use **⋮ → Update Variables** before
deploying.

### ⚠️ `rollout restart` does NOT fix this either

The wrong value is **persisted**, not in memory. Restarted pods mount the same ConfigMap and read
the same dead ID.

| Situation | Action |
|---|---|
| Config is right, process is stuck (e.g. Mongo pool paused) | `rollout restart` |
| **Config value is wrong** (this case) | Fix the Octopus variable → **new release** |

### Do not use a Clean release

It rebuilds the app registration again, breaking anything that consumes this app. See
[SOP-mongo-connection-pool-paused](SOP-mongo-connection-pool-paused.md).

## Step 4 — Verify it actually landed

```bash
kubectl -n <ns> get cm <app>-chart -o jsonpath='{.data.VITE_AUTH_CLIENT_ID}{"\n"}'
kubectl -n <ns> get rs -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp,REPLICAS:.status.replicas
```

**A new ReplicaSet plus the corrected ID is the proof.** The same ReplicaSet hash means nothing
rolled, regardless of what Octopus reported.

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
| **Real source** | Octopus **project variable** — hand-maintained, not generated |
| **Fix** | Correct the variable → **new release** (not a re-deploy) |
| **Won't work** | `rollout restart`; re-deploying an existing release (stale variable snapshot) |
| **Never** | Clean release; or judging a SPA by a `client_credentials` test |
| **Proof** | New ReplicaSet **and** the corrected ID in the ConfigMap |

Incident: `wip/incidents/2026-08-12-edi-spa-stale-client-id.md`
