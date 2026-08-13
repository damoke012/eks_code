# /prod-auth-triage

Triage 401 / audience / token failures on the AWS EKS prod cluster (`usxpress-prod`), where the
cause is usually a recreated Entra app registration rather than anything in Kubernetes.

Built from the 2026-08-10 `orders-api` total outage — six hours, 100% 401, 18 affected consumers.

## When to use

- `IDX10214: Audience validation failed`, `AADSTS500011`, `AADSTS501051`, or blanket 401s from a
  prod API.
- An app "returns 401 on everything but the pods are healthy".
- Anyone proposes redeploying a prod service to fix an auth error.

## Rule zero — check the instrument before trusting any reading

Most prod apps here run with `otel.logging.enabled: false` and **log no HTTP requests at all**.
App logs going quiet is NOT recovery. The only reliable source is the istio-proxy access log, which
is **JSON** — `grep ' 401 '` silently returns zero.

Access logging is already on mesh-wide (`accessLogFile: /dev/stdout`, `accessLogEncoding: JSON` in
`istio-system/istio`; `mesh-default` Telemetry configures **tracing only**). So a namespace
Telemetry to "enable" it is a no-op — don't add one. Verified 2026-08-13.

**An empty access log is ambiguous**, and three things cause it. Rule them out in order:

```bash
kubectl -n <ns> get pods                      # logs deploy/X reads ONE pod — check each
kubectl -n <ns> logs <pod> -c istio-proxy --since=30m --tail=30000 | wc -l
kubectl -n <other-ns> logs deploy/<busy-app> -c istio-proxy --since=5m | wc -l   # known-good control
```

1. **No traffic.** Confirm from the caller's side before concluding anything.
2. **Wrong pod** — `logs deploy/X` picks the first pod only.
3. **~1 hour retention** — a 12h query returns the same lines as a 60m one.

The sidecar may be a **native sidecar** under `initContainers`, so `.spec.containers[*]` shows only
the app. `kubectl logs -c istio-proxy` still works.

```bash
export KUBECONFIG=$HOME/.kube/prod.yaml
kubectl cluster-info | head -1          # MUST read BF7BD089…
L=$(kubectl -n <ns> logs deploy/<app> -c istio-proxy --since=15m --tail=8000 2>/dev/null)
echo "$L" | jq -r .response_code | sort | uniq -c | sort -rn
echo "$L" | jq -r '(.x_forwarded_for // .downstream_remote_address) + "  " + (.response_code|tostring)' | sort | uniq -c | sort -rn | head
echo "$L" | tail -1                      # eyeball a raw line before trusting any count
```

`172.24.x` = in-cluster caller. `10.10.x` = corporate/on-prem caller (their config is NOT in the
cluster and cannot be fixed with kubectl).

## Phase 1 — has the app registration been recreated?

```bash
aws secretsmanager describe-secret --secret-id azure-app-dx-prod-usxpress-<app> --profile usx-prod \
  --query '{Created:CreatedDate,LastChanged:LastChangedDate}'
```

`Created` == `LastChanged` == today (seconds apart) → **destroyed and recreated**, new client ID.
`recovery_window_in_days = 0`, so there is no version history and the old credential is gone.

**This is the best fleet-wide fingerprint of a clean release** — independent of Octopus and Entra,
and it works historically. Two shapes:

| Shape | Meaning |
|---|---|
| `Created` old, `LastChanged` recent | **ordinary deploy** — secret rotated in place, registration untouched |
| `Created` == `LastChanged`, both recent | **destroyed and rebuilt** — new client ID |

`freight-allocation-api` created 2024-07-29 and still deploying 2026-07-16 is the first shape.
`orders-api` created 2026-08-10T18:35 after years of existence is the second. Sweep the fleet:

```bash
for s in $(aws secretsmanager list-secrets --profile usx-prod \
    --query 'SecretList[?starts_with(Name,`azure-app-dx-prod-usxpress`)].Name' --output text); do
  aws secretsmanager describe-secret --secret-id "$s" --profile usx-prod \
    --query '[Name,CreatedDate,LastChangedDate]' --output text
done | sort -k2
```

A third witness: a clean release destroys the **Deployment object**, so all its ReplicaSets share
one `creationTimestamp`. `kubectl -n <ns> get rs -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp`

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=azure-app-dx-prod-usxpress-<app> \
  --profile usx-prod --start-time 2026-06-01T00:00:00Z --max-results 50 \
  --query 'Events[?EventName==`DeleteSecret`||EventName==`CreateSecret`].{Time:EventTime,Event:EventName}' --output table
```

Entra side (needs `az login --tenant bbb5a66d-5c9f-482a-969a-a40304b6bc8d --scope https://graph.microsoft.com//.default`):

```bash
az rest --method GET --url "https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.application" \
  --query "value[?contains(displayName,'<app>')].{name:displayName,appId:appId,deleted:deletedDateTime}"
az rest --method GET --url "https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?\$filter=activityDisplayName eq 'Delete application'&\$top=25" \
  --query "value[].{time:activityDateTime,actor:initiatedBy.user.userPrincipalName,app:initiatedBy.app.displayName,target:targetResources[0].displayName}"
```

`DX-Terraform-App-Creator` as the actor = the DX deploy pipeline did it.

## Phase 2 — map every affected consumer

```bash
kubectl get cm -A -o json | jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $n |
 (.data // {}) | to_entries[] | select(.key|startswith("AUTH__ApiAppScopes__")) |
 "\($ns)/\($n)\t\(.key|sub("AUTH__ApiAppScopes__";""))\t\(.value)"' | sort
```

```bash
for s in $(aws secretsmanager list-secrets --profile usx-prod \
    --query 'SecretList[?starts_with(Name,`azure-app-dx-prod`)].Name' --output text); do
  cid=$(aws secretsmanager get-secret-value --secret-id "$s" --profile usx-prod \
        --query SecretString --output text 2>/dev/null | jq -r '.AUTH__ClientId // "-"')
  printf '%s\t%s\n' "$cid" "${s#azure-app-dx-prod-usxpress-}"
done | sort
```

Any GUID in the first list absent from the second is a stale consumer. **Check every API, not just
the reported one** — the 2026-08-10 sweep found three stale APIs, two broken silently for four days.

**Then widen it — `AUTH__ApiAppScopes__*` is NOT the only place a sibling's client ID is stored.**
`*-chart` ConfigMaps carry hardcoded GUIDs under arbitrary keys (`OrdersLumperApi__AUTH__ClientId`,
`Mulesoft__Authorization__ClientId`, `VITE_AUTH_CLIENT_ID`, …):

```bash
kubectl get cm -A -o json | jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $n |
 (.data // {}) | to_entries[] |
 select(.value|test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(/\\.default)?$")) |
 "\($ns)/\($n)\t\(.key)\t\(.value)"' | sort | grep -vi apiappscopes
```

Triage the results against `/tmp/dx-ids.txt`:
- resolves to a **different** `dx-prod-usxpress-*` app → **at risk**, same bug
- resolves to the holder's **own** registration (UI SPAs) → self-reference, safe
- **not** a `dx-prod-*` registration → external third party (Platform Science `eed80dd9`, Mulesoft
  `11d9f3a0`, Netradyne, Cisive, Lytx, Chewy, KnightSwift) → immune
- `bbb5a66d-5c9f-482a-969a-a40304b6bc8d` is the **tenant ID**, not a client ID

## Phase 3 — PROVE the fix before changing anything

```bash
S=$(aws secretsmanager get-secret-value --secret-id azure-app-dx-prod-usxpress-<consumer> \
     --profile usx-prod --query SecretString --output text)
TEN=$(echo "$S"|jq -r .AUTH__TenantId); CID=$(echo "$S"|jq -r .AUTH__ClientId); CSEC=$(echo "$S"|jq -r .AUTH__ClientSecret)
unset S
curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  -d "client_id=$CID" -d "client_secret=$CSEC" -d "grant_type=client_credentials" \
  -d "scope=<resource-or-uri>/.default" | jq -r 'if .access_token then "TOKEN ACQUIRED" else .error_description end'
```

Read-only; failures are authorization-stage so credentials are untouched. Disclose the failed
service-principal sign-ins in the incident thread so they aren't mistaken for a symptom.

| Result | Meaning |
|---|---|
| `AADSTS500011 resource principal not found` | the API's registration was deleted — consumer points at a dead identity |
| `AADSTS501051 not assigned to a role` | scope is right but the **app-role assignment** was destroyed — a config change will NOT fix it |
| `TOKEN ACQUIRED` | decode `aud` and compare with the API's `AUTH__ClientId` |

## Phase 4 — the fix

**A full consumer RELEASE is required.** It does two things a config patch cannot: refreshes the
scope, and re-grants `azuread_application_api_access.role_access_for_other_api`. Verified working
2026-08-10 — MOSH's release granted the assignment at 00:57:06 and 200s appeared within minutes.

**Sequence releases by dependency**, because each release recreates that service's own registration
and breaks *its* consumers: leaves first, most-consumed services last.

Confirm each one:

```bash
az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/<api-sp-id>/appRoleAssignedTo" \
  --query "value[].{consumer:principalDisplayName,when:createdDateTime}" -o table
```

**Alternative, zero releases:** restore the deleted application *and* service principal from Entra
(`POST /directory/deletedItems/{id}/restore`, 30-day window). Brings back the appId and its role
assignments. Requires freeing `api://dx-<env>-<name>` from the replacement first, and repointing the
API's own `AUTH__ClientId`. Leaves Terraform drift — the next deploy undoes it.

## SPAs are a different failure mode — check this FIRST if the app is a UI

If `deploy/ui.yaml` declares `type: spa`, most of the above does not apply.

**A SPA uses delegated scopes (`user_impersonation`) via authorization-code + PKCE. It is never
assigned an app role.** So a `client_credentials` test against its API returns
`AADSTS501051 — not assigned to a role` **on a perfectly healthy SPA**. That test proves nothing and
has already misdirected one investigation (2026-08-12, EDI).

The usual SPA fault is a **stale client ID persisted in the ConfigMap**:

```bash
kubectl -n <ns> get cm <app>-chart -o jsonpath='{.data.VITE_AUTH_CLIENT_ID}{"\n"}'
az ad app list --all --query "[?displayName=='dx-<env>-usxpress-<app>'].appId | [0]" -o tsv
```

Different → the frontend is announcing an identity that no longer exists.

**DX generates this value** — the deploy emits `client_id` from Terraform and logs `Updating
manifest with output variables`. Healthy UIs (`fade-ui`, `ocs-ui`, `pam-ui`) declare no auth entry
in `ui.configVars` and self-heal. The broken ones (`edi-management-ui`, `customer-profile-ui`,
`xra-ui`) declare `VITE_AUTH_CLIENT_ID: '#{...}'`, which **overrides DX's output** with a
hand-maintained Octopus variable — so a redeploy just rewrites the stale value.
Confirm which pattern an app uses from its deploy manifest:

```bash
T=$(curl -s -H "X-Octopus-ApiKey: $K" "$O/api/$SP/deployments/<Deployments-N>" | jq -r .TaskId)
curl -s -H "X-Octopus-ApiKey: $K" "$O/api/tasks/$T/details?verbose=true" \
  | jq -r '[.. | objects | select(has("LogElements")) | .LogElements[]] | .[] | .MessageText' \
  | grep -o 'ctx={.*}' | head -1 | sed 's/^ctx=//' | jq -r '.ui.configVars'
```

Fix the Octopus variable per environment, then **create a NEW release**: Octopus snapshots variables
at release creation, so re-deploying an existing release replays the old value and goes green having
changed nothing. Proof it landed = a **new ReplicaSet** plus the corrected ID.

Sweep every SPA at once:

```bash
kubectl get cm -A -o json | jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $n |
 (.data // {}) | to_entries[] | select(.key|test("(?i)VITE_AUTH_CLIENT_ID")) |
 "\($ns)/\($n)\t\(.value)"'
```

Verify the API side is actually fine before blaming it — for SPAs the grant is
`preAuthorizedApplications`, not `appRoleAssignedTo`:

```bash
az rest --method GET --url "https://graph.microsoft.com/v1.0/applications(appId='<api>')" \
  --query "{name:displayName, preAuth:api.preAuthorizedApplications, scopes:api.oauth2PermissionScopes[].{id:id,value:value}}" -o json
```

`preAuth[].appId` must equal the UI's **current** client ID, and its `delegatedPermissionIds` must
appear in `scopes[].id`.

Runbook: `docs/runbooks/SOP-spa-auth-client-id.md`.

## Restart vs redeploy

- **Config is right, process is stuck** (e.g. MongoDB "connection pool is in paused state") →
  `kubectl rollout restart`. Rolling, zero downtime. It does **not** scale to zero.
- **Config itself is wrong** (stale client ID in a ConfigMap) → **redeploy**. A restart re-reads the
  same bad value.
- **Never a clean release for either** — it rebuilds the app registration and breaks every consumer.
  See `docs/runbooks/SOP-mongo-connection-pool-paused.md`.

## Phase 5 — the durable fixes to file

1. `terraform-azuread-app/outputs.tf` should emit `identifier_uris[0]` (deterministic,
   `api://dx-${env}-${name}`) instead of `client_id`, which goes stale on every recreation.
2. Find out **why a deploy deletes the app registration at all** — rotating a password should never
   destroy the application. That is the fault behind every occurrence.
3. `recovery_window_in_days = 0` destroys the only copy of the credential. Raise it.

## Anti-patterns

- **Redeploying the failing API.** Its config is usually correct; the consumers are stale. Each
  redeploy mints another client ID and widens the gap. This happened three times on 2026-08-10.
- **Kubernetes rollback.** Auth values come from `envFrom` → Secret → ESO → Secrets Manager. Every
  ReplicaSet reads the same current Secret; rollback is a no-op. Verify with
  `kubectl get rs -l app=<app> -o json | jq '.items[].spec.template.spec.containers[0].envFrom'`.
- **Patching only the scope string.** Fails with `AADSTS501051`.
- **Declaring recovery from app logs.** They do not record HTTP.
- **Removing authentication as a mitigation** without a named revert owner and a date.
