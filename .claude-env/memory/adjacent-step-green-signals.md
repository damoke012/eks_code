---
name: adjacent-step-green-signals
description: "The recurring on-prem failure family: a component reports success about a step ADJACENT to the one that matters. Ten instances by 2026-08-20; only executable checks catch it."
metadata:
  node_type: memory
  type: feedback
---

The single most expensive pattern in on-prem platform work: a green signal that is **true**,
about a step **next to** the one you care about. Twelve instances by 2026-08-21, all but one found in two days.

| Reports | Actually proves | Does NOT prove |
|---|---|---|
| ExternalSecret `SecretSynced` | the sync ran | the value works ([[eso-secretsynced-not-content-check]]) |
| Argo CD `Synced Healthy` | manifests match Git | the workload runs (it was in `ImagePullBackOff`) |
| Flux `Ready=True` | the kustomization built and applied | the thing it applied functions |
| external-dns `Desired change: CREATE` | intent, logged *before* the API call returns | a record exists |
| VirtualService exists | an object exists | it is bound — a missing Gateway is silent on both objects |
| `readinessProbe: tcpSocket{port: status}` | the status listener is up | the **data** port is (INFRA-1654: 11 weeks dead) |
| `POSTGRES_PASSWORD` set | initdb used it once | the current secret works ([[qa-postgres-password-drift]]) |
| `secretKeyRef` env present | the pod resolved it at creation | it matches the secret now ([[pod-env-secret-resolution]]) |
| `kubectl get gateway` empty | that API group has none | the Istio one is absent (wrong group) |
| a `curl` `000` | curl got no response | whether DNS or connect failed — `--resolve` separates them |
| Argo CD `operationState: Succeeded` | a sync succeeded **once, at some past time** | that the app can reach its repo now — it sat there 18h while `sync=Unknown` (2026-08-21) |
| a connect to `kubectl port-forward`'s local socket | kubectl bound a local port | that the **pod** listens — kubectl binds before contacting the pod, and reports the pod-side outcome only on its own stderr |

**Why:** each signal is emitted by a component reporting on its own job, which it did. Nothing
in the stack is responsible for asserting the end-to-end property, so nothing does.

**How to apply:** never accept a status field as evidence for a claim about behaviour. Prove
behaviour by exercising it. Notes describing these traps demonstrably do NOT prevent them —
the `external-dns` target requirement was already written down in
[[onprem-networking-ingress]] and was still missed on 2026-08-20. Only executable checks work:
`scripts/check-onprem-route.sh` (route: object → backend → authoritative DNS vs local resolver
→ HTTP or SNI handshake), `scripts/check-postgres-secret-usable.sh` (authenticates, not
compares), `scripts/check-foreign-cluster-ids.sh` ([[manifests-copied-across-branches]]).
When a fix is found, ask what check would have gone red, and write that instead of a paragraph.

⚠️ **And then watch the check go red.** Instance 11 was inside
`scripts/check-service-ports-listening.sh` — the detector written *for this family* — which
reported a known-dead port as healthy on its first run. It was argument-tested, reasoned
about, and structurally incapable of finding the one bug it existed for. The only reason this
surfaced is that it was pointed at a namespace where the answer was already known by an
independent method. **A check nobody has seen fail is a hypothesis.** Validate every new check
against a defect you have already confirmed some other way, before trusting it anywhere.
