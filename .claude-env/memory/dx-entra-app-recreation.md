---
name: dx-entra-app-recreation
description: "DX deploys DESTROY and recreate an app's Entra registration (new client ID + lost role grants) — consumers cache the callee's client ID and break silently. Root cause of the 2026-08-10 prod orders-api total outage."
metadata: 
  node_type: memory
  type: project
  originSessionId: e3125f37-c991-4364-adf2-b40770a2d61c
  modified: 2026-08-11T01:05:06.114Z
---

**Every DX deploy of an app deletes and recreates its Azure AD app registration.** New client ID
every time. `terraform-variant-apps/modules/common/auth` → `terraform-azuread-app` (`?ref=v5.0`),
run by the Octopus worker (`arn:aws:sts::937464026810:assumed-role/octopus-usxpress/*`). Entra audit
log attributes the deletions to service principal **`DX-Terraform-App-Creator`**.

**Why it breaks callers.** `terraform-azuread-app/outputs.tf` emits
`AUTH__ApiAppScopes__${ref} = "${data.azuread_application.api_apps[name].client_id}/.default"` — a
**data-source snapshot of ANOTHER app's client ID, taken when the CONSUMER deploys**. Nothing
regenerates it when the callee is recreated. Consumers then request a resource principal that no
longer exists → `AADSTS500011`, or hold a valid-looking token with the wrong audience → `IDX10214`.

**⚠️ A config change alone does NOT fix it — a full consumer RELEASE is required.**
Proven 2026-08-10: patching only the scope string fails with
`AADSTS501051: <consumer> is not assigned to a role for <api>`. Recreating the registration also
destroys every consumer's **app-role assignment**. A release re-grants it
(`azuread_application_api_access.role_access_for_other_api`) AND refreshes the scope. Both halves.

**Release order matters** — each consumer's release recreates *its own* registration and breaks
*its* consumers. Leaves first, then mid-tier, then the most-consumed last.

**Map the consumer graph** (single command, read-only, prod):
```
kubectl get cm -A -o json | jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $n |
 (.data // {}) | to_entries[] | select(.key|startswith("AUTH__ApiAppScopes__")) |
 "\($ns)/\($n)\t\(.key|sub("AUTH__ApiAppScopes__";""))\t\(.value)"' | sort
```
Compare each GUID against the live value in
`aws secretsmanager get-secret-value --secret-id azure-app-dx-<env>-usxpress-<app> | jq .AUTH__ClientId`.
Any mismatch = that consumer is broken or will break on its next call.

**Prove a fix BEFORE changing anything** — acquire a token exactly as a consumer would:
```
S=$(aws secretsmanager get-secret-value --secret-id azure-app-dx-prod-usxpress-<consumer> \
      --profile usx-prod --query SecretString --output text)
curl -s -X POST "https://login.microsoftonline.com/$(echo "$S"|jq -r .AUTH__TenantId)/oauth2/v2.0/token" \
  -d "client_id=$(echo "$S"|jq -r .AUTH__ClientId)" -d "client_secret=$(echo "$S"|jq -r .AUTH__ClientSecret)" \
  -d "grant_type=client_credentials" -d "scope=<resource>/.default" | jq
```
Failures are authorization-stage, so credentials are unaffected and nothing is created. Decode `aud`
from the JWT payload to confirm it matches the API's `AUTH__ClientId`. **This test is what stopped us
telling 18 teams to make a change that would not have worked.**

**Other durable facts**
- `recovery_window_in_days = 0` on the SM secret → deleted credentials are **unrecoverable**, and the
  secret shows a single version with no history. A `CreateSecret` (not `PutSecretValue`) in CloudTrail
  means destroy-and-recreate.
- Entra **deleted applications AND service principals are recoverable for 30 days**
  (`/directory/deletedItems/microsoft.graph.{application,servicePrincipal}` → `POST {id}/restore`).
  Restoring brings back the appId *and* the role assignments — but the App ID URI is unique, so the
  replacement registration must release `api://dx-<env>-<name>` first.
- `identifier_uris = ["api://dx-${environment}-${name}"]` is **deterministic and survives recreation**.
  Emitting that instead of `client_id` in `outputs.tf` would remove this whole failure class.
  **Not yet done** — the regenerated scope is still a GUID.
- `requestedAccessTokenVersion: 2` → `aud` is the resource's **client ID**, not the URI.

Related: [[no-test-pods-in-prod]], [[eso-secretsynced-not-content-check]], [[entra-secret-rotation]],
[[prod-incident-instrument-check]].
