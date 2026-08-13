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

## Why this only happens to UIs, never to APIs

This is the question application teams push back on — *"why should we ever hand-edit a variable?"*
They are right that they shouldn't. Here is why the two behave differently today.

Every DX app's Entra identity is created by Terraform. There are two ways it reaches the app:

| | Service (`-api`, `-handler`, `-cron`) | SPA (`-ui`, `type: spa`) |
|---|---|---|
| Path | Terraform → Secrets Manager → ESO → Secret → `envFrom` | Octopus variable → `#{VITE_AUTH_CLIENT_ID}` → ConfigMap |
| Written by | Terraform, on every deploy | A person, once |
| After the registration is recreated | Next release repairs it automatically | Stale forever |

A browser cannot hold a client secret, so a SPA cannot read from the ESO-synced Secret the way a
service does — its ID must arrive as plain build config, and nothing wires Terraform into
`configVars`.

**Consequence:** an environment only needs a manual variable edit if the app that was rebuilt is a
UI. Prod's August 2026 clean releases were all services (`orders-api`, `graphql-gateway`, `mosh`,
…) so they self-healed; QA's was `edi-management-ui`, so it did not. Prod is not protected — it has
simply never had a UI clean-released.

Durable fix tracked in `wip/incidents/2026-08-13-bug-spa-client-id-hand-maintained.md`.

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

**Prove it from the API before arguing about it.** If the newest release's `Assembled` timestamp
predates the variable correction, no deploy can have carried the new value:

```bash
: "${O:?}"; : "${K:?}"; : "${SP:=Spaces-245}"; P=Projects-9242   # <- the UI's project

VL=$(curl -s -H "X-Octopus-ApiKey: $K" "$O/api/$SP/projects/$P" | jq -r '.Links.Variables')
curl -s -H "X-Octopus-ApiKey: $K" "$O$VL" | jq -r '.Variables[]
  | select(.Name|test("VITE_";"i"))
  | "\(.Name)\t\((.Scope.Environment // ["ALL"])|join(","))\t\(.Value)"' | sort
curl -s -H "X-Octopus-ApiKey: $K" "$O$VL" | jq -r '.ScopeValues.Environments[] | "\(.Id)\t\(.Name)"'

curl -s -H "X-Octopus-ApiKey: $K" "$O/api/$SP/projects/$P/releases?take=6" \
  | jq -r '.Items[] | "\(.Version)\t\(.Assembled)\t\(.Id)"'
curl -s -H "X-Octopus-ApiKey: $K" "$O/api/$SP/deployments?projects=$P&take=6" \
  | jq -r '.Items[] | "\(.Created)\t\(.EnvironmentId)\t\(.ReleaseId)\t\(.Id)"'
```

2026-08-12 EDI: variable correct, newest release assembled 08-10T17:41 — twenty-one minutes *before*
the registration was destroyed — and every deployment since replayed that same `Releases-97125`.
Variable right, snapshot stale, cluster unchanged.

Also check the **scoping**, not just the value. EDI held one `VITE_AUTH_CLIENT_ID` row scoped to
*both* development and qa, which cannot be correct — the two environments have different
registrations. Look for any auth variable whose scope covers more than one environment.

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
