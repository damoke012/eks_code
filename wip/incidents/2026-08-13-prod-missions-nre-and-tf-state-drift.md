# Prod — missions NRE, and a deploy blocked by Terraform state drift (2026-08-13)

**Services:** `missions/usx-missions-api`, `orders/order-api` · **Cluster:** `usxpress-prod`
**Reported by:** Pramisha Thapaliya · **Resolved:** 0.1.58 deployed, errors → zero

---

## Part 1 — the application fault

**Symptom:** *"Outbound/inbound missions is not getting created when equipmentType is switched to
Power Only"*, plus 500s from `orders-api /v1/orders/get-by-order-ids`.

**Root cause — one method.** Every failure, from three different strategies, bottomed out in the
same place:

```
System.NullReferenceException: Object reference not set to an instance of an object.
   at Missions.Application.Services.ArrivalDepartureService.CreateMission(
        OrderInfo orderDb, MissionType missionType, ILogger, IMissionRepository, Boolean createLeg)
```

```
EquipmentTypeMissionCreationDataPatchStrategy.Execute  (…Strategy.cs:48)
  └─ CreateMissionWithInboundLeg  → CreateMission ✗
OutboundTrailerReturnDataPatchStrategy.ExecuteTrailerReturnPatch
  └─ PatchProcessingBasedOnNewOutboundLeg → CreateMissionWithOutboundLeg → CreateMission ✗
```

**It only throws when a mission must be created.** The log distinguishes the two paths cleanly:

| Preceding line | Outcome |
|---|---|
| `Need to create mission for MongoOrder: 9718394` | **NRE** |
| `Mission already exists for MongoOrder: 9701375` | passes, skips cleanly |

That is why it presented as "missions aren't being created" rather than a general outage.

**The line** (found by Matt McNabb, confirmed from prod data):

```csharp
AuditInfo = new AuditInfo { UserId = destination.Appointment?.Audit.UserId ?? string.Empty, }
//                                                      ↑ guards Appointment only
//                                                                ↑ throws when Audit is null
```

Production payload for order 2265674 matches exactly — `Appointment` populated, `Audit: null`, on
Origin, Destination, PreviousStop and every entry in `Stops[]`. Fix is the second null-conditional:
`Appointment?.Audit?.UserId`.

**Impact:** ~6 failures/minute sustained. Distinct orders seen in an 8½-minute window: 2271544,
2272876, 2272891, 2272917, 2271407, 2272230, 2271076, 2272590, 2272591.

**Verified fixed:** after 0.1.58, `grep -c 'ArrivalDepartureService.CreateMission'` over 5 minutes
returned **0**, against ~30 in a comparable window before.

### What it was NOT

- **Not the Mongo connection pool.** Zero `paused state` lines in 12h.
- **Not auth.** A token failure returns 401/403 at the gateway; a 500 means the handler ran and
  threw. `order-api` also still has authentication removed (PR #182, 11 Aug).
- **Not fallout from Monday's clean releases.** `order-api` pods were 2d8h old with 0 restarts.

---

## Part 2 — the deployment could not go out

Release 0.1.58 failed twice at `Step 1: DX-Apply`.

### Failure A — state drift

```
Error: configmaps "usx-missions-api-iaac-replicator" already exists   (Replicator)
Error: configmaps "usx-missions-api-m-u"             already exists   (Mongodb-User)
Error: secrets    "usx-missions-api-m-i"             already exists   (Mongodb-User)
```

The objects existed in the cluster but not in DX's Terraform state, so the apply tried to create
them. All three had `creationTimestamp` from **minutes earlier** — orphans from a prior failed
apply, not long-standing objects. Deleting them let the next apply create and record them.

### Failure B — deadlock

The next run reached `[Api] Started Tf Apply` and hung, eventually failing with:

```
Error: context deadline exceeded
  with helm_release.api, on main.tf line 84
error resolving secrets for ScaleTarget: … ConfigMap "usx-missions-api-m-u" not found
```

`usx-missions-api-m-u` is consumed by the Deployment via `envFrom`, so the new pod could not start
(`CreateContainerConfigError`) — and Helm was waiting for a rollout that could never complete.

**Recovery:** read the ConfigMap's exact content out of Terraform state in S3 and reapply it, then
let the rollout finish.

```bash
aws s3 cp s3://usxpress-tf-state-25cypfeqq8xpf582/USXpress/usx-missions-api/common/mongodb-user - \
  --profile usx-prod \
  | jq -r '.resources[] | select(.type=="kubernetes_config_map_v1") |
           {name:.name, metadata:.instances[].attributes.metadata, data:.instances[].attributes.data}'
```

Two keys, no secrets (`MONGODB__CLUSTER__CONNECTION_STRING`, `MONGODB__CLUSTER__SERVER`). Reapplied
with identical content and labels so state stayed valid. Pods went Running, rollout completed, and
the re-run went green in one minute.

Note: `kubectl apply` reported `configured`, not `created` — Terraform had restored it moments
earlier, so the manual apply normalised rather than rescued it. The precise ordering between the
mongodb-user apply and the Helm wait is still not established.

### Why the drift existed

`azure-app-dx-prod-usxpress-usx-missions-api` last changed **2025-05-08**. This project had not had
a successful prod deploy in **fifteen months**. Projects that don't deploy regularly fail exactly
when they're needed, under incident pressure.

---

## Part 3 — the same day, two other projects

`trailer-validation-alert-api` and `usx-orders-auto-booking-handler` both failed to deploy. Rohit
Saini's diagnosis: the releases pin old `mage` / `tf-apps` versions that emit
`external-secrets.io/v1beta1`, which no longer exists in the cluster. Fix was an **empty commit →
new release** so the package picks up current tooling. Both landed and were verified by Pramisha.

**This is a second clean-release generator.** The first is the Mongo pool pause. This one fires on
any project that has gone stale, and the failure *looks* like it needs a clean release. See
`docs/runbooks/SOP-dx-deploy-failure-recovery.md`.

No registration was recreated during any of today's work — `usx-missions-api` kept client ID
`dd0d634d-efef-4b13-b762-2e9cfd9745f8` throughout.

---

## Observability gaps confirmed

- The mesh **does** have access logging on globally (`accessLogFile: /dev/stdout`,
  `accessLogEncoding: JSON`); `mesh-default` in `istio-system` configures tracing only. A namespace
  Telemetry to "enable" logging is therefore a no-op.
- `order-api` nonetheless emitted no access-log lines in 45 minutes. Unresolved — either genuinely
  no traffic (missions made zero `get-by-order-ids` calls in the same window) or a per-workload
  gap. Worth settling with a known trigger.
- `otel.logging.enabled: false` on these services means **app logs record no HTTP at all**. The
  mesh can give status, path, caller and timing; it cannot give the request body, which is what the
  application team needed. That needs `otel.logging.enabled: true` in the app spec.

## Follow-ups

1. **Sweep prod projects by last successful deploy** and clear the stale backlog deliberately.
2. **Raise the `already exists` / Helm-wait deadlock** with the DX team — recovery required reading
   raw Terraform state, which application teams cannot do.
3. **`order-api` HTTP logging** — `otel.logging.enabled: true`, small spec change, would have
   shortened the 10 Aug incident materially.
4. **Question for Buddy:** the *production* spec for `usx-missions-api` carries
   `DATABASE__User: qa_temp_user`, `ORDERS_DATABASE__User: qa_missions_api_…`,
   `LOCATIONS_DATABASE__User: qa_temp_user`, hosts `usxd2vmmongodv1/v2`, `replicaSet=dev1`. May be
   legacy on-prem naming; if not, prod is reading and writing a non-prod database.
5. **`order-api` authentication is still removed** (PR #182, 11 Aug). Needs a named owner and a
   revert date.

Related: [SOP-dx-deploy-failure-recovery](../../docs/runbooks/SOP-dx-deploy-failure-recovery.md) ·
[SOP-mongo-connection-pool-paused](../../docs/runbooks/SOP-mongo-connection-pool-paused.md)
