---
name: adjacent-step-green-signals
description: "The recurring on-prem failure family: a component reports success about a step ADJACENT to the one that matters. Ten instances by 2026-08-20; only executable checks catch it."
metadata:
  node_type: memory
  type: feedback
---

The single most expensive pattern in on-prem platform work: a green signal that is **true**,
about a step **next to** the one you care about. Ten instances found by 2026-08-20, most of
them in one day.

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
