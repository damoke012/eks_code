---
name: adjacent-step-green-signals
description: "The recurring on-prem failure family: a component reports success about a step ADJACENT to the one that matters. Nineteen instances by 2026-09-03, including checks that share the defect they test for and one that never ran at all; only executable checks catch it."
metadata:
  node_type: memory
  type: feedback
---

The single most expensive pattern in on-prem platform work: a green signal that is **true**,
about a step **next to** the one you care about. Nineteen instances by 2026-09-03.

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
| a `PrometheusRule` present and `Ready` | the rule was authored, applied and parsed | that it can ever fire — an expression selecting a metric that is never ingested is valid, healthy and permanently `inactive` ([[onprem-alerts-not-delivered]]) |
| a PodMonitor with **4 targets, all `up`, no errors** | the scrape works | that the metric exists — `gotk_reconcile_condition` was removed upstream, and a working scrape of a never-emitted metric is indistinguishable from no scrape (2026-08-24) |
| **one** of two alerts firing | the rule fires for *that* failure shape | that it fires at all — `wiz-sensor` fired because it is *stalled*; `risingwave` never did because it *cycles*, and one of two firing is exactly what lets you call it done |
| an alert reaching `firing` | the expression matched for one `for:` window | that it will stay — a churning label in the output resets `activeAt`, so it re-enters `pending` forever |
| **a verification query returning a number** | the query ran | that the query is sound — `count_over_time` counts per *series*, splitting a flapping object exactly the way the broken alert did; it returned `1`, and the bug reported itself as a result (2026-08-24) |

**Why:** each signal is emitted by a component reporting on its own job, which it did. Nothing
in the stack is responsible for asserting the end-to-end property, so nothing does.

**How to apply:** never accept a status field as evidence for a claim about behaviour. Prove
behaviour by exercising it. Notes describing these traps demonstrably do NOT prevent them —
the `external-dns` target requirement was already written down in
[[onprem-networking-ingress]] and was still missed on 2026-08-20. Only executable checks work:
`scripts/check-onprem-route.sh` (route: object → backend → authoritative DNS vs local resolver
→ HTTP or SNI handshake), `scripts/check-postgres-secret-usable.sh` (authenticates, not
compares), `scripts/check-foreign-cluster-ids.sh` ([[manifests-copied-across-branches]]),
`scripts/check-alert-delivery.sh` (is there a sink, and does each rule's metric exist).
When a fix is found, ask what check would have gone red, and write that instead of a paragraph.

⚠️ **The check itself joins this family.** On 2026-08-24 four fixes in a row were each
verified by something that shared the defect it was checking for, and two guard scripts
refused a branch that was already correct — one matched **the comment explaining that the
problem was fixed**, the other compared a note to itself byte-for-byte and appended a
duplicate. Before trusting a check, ask what it would report if the defect were present
*and* if it were absent; if those are the same output, it is not a check. Fixture-test a
guard against every branch state it will meet — already-fixed, not-yet-fixed, already-run —
not only the one in front of you.

⚠️ **And then watch the check go red.** Instance 11 was inside
`scripts/check-service-ports-listening.sh` — the detector written *for this family* — which
reported a known-dead port as healthy on its first run. It was argument-tested, reasoned
about, and structurally incapable of finding the one bug it existed for. The only reason this
surfaced is that it was pointed at a namespace where the answer was already known by an
independent method. **A check nobody has seen fail is a hypothesis.** Validate every new check
against a defect you have already confirmed some other way, before trusting it anywhere.

**2026-09-02 — `az ad app permission admin-consent` exits 0 having granted nothing.**
It consents to whatever the registration lists in `requiredResourceAccess`. An app that
declares none — because `openid profile email` are implicit — gives the command nothing to
do, so it succeeds silently and the grants stay `consentType: Principal`. Every user keeps
hitting the consent screen while the command that was supposed to fix it reported success.
Read `/servicePrincipals/<id>/oauth2PermissionGrants` back and look for `AllPrincipals`;
the tenant-wide grant can be created directly with a Graph POST.

Fourth instance in one day of the same shape — a variable snapshot, a region-less secret
probe, a no-op string replace, and now this. **A command that prints nothing on success
prints nothing on no-op either.**

**Instance 18 — 2026-09-03. The maintenance script had never run a third of itself.**
`scripts/weekly-maintenance.sh` carried `exit 0` immediately after section 7's summary, so
sections **8 (lint-shell-prose) and 9 (Flux revision drift) were unreachable dead code**.
Every run printed a finding count and exited clean. The script whose whole job is catching
rot had been reporting success on checks it never executed — the family's own pattern, in the
tool built to detect the family. Found by accident while adding sections 10 and 11.

**How to apply:** a check's exit code proves it ran *to completion*, not that it ran *at all*.
Count the sections in the output against the sections in the file. Anything after an
unconditional `exit` is decoration.

**Instance 19 — 2026-09-03. A gate with no passing branch.**
`rw-prod-status.sh` gate 5 counted ExternalSecret rows where `$NF != "SecretSynced"`. But
`kubectl get externalsecrets` prints NAME STORE REFRESH **STATUS READY**, so `$NF` is READY
("True") and never equals "SecretSynced". Every row always matched. Against a namespace where
all seven were genuinely synced it reported **"7 ExternalSecret(s) not SecretSynced"**, and
sent an hour into diagnosing a healthy cluster. The same gate looked for the licence under
`risingwave-console-license`; the object is `rw-license-key`, so it returned UNKNOWN — a name
guessed wrong reads exactly like a thing that is not there.

**Three in one session**, all in checks written *because of* an earlier incident:
`weekly-maintenance.sh` exiting before a third of its own sections, a line-based grep for
`--base` that missed continuation lines, and this. **The checks are now the most defect-dense
code in the repo, and nothing tests them.**

**How to apply:** a gate must be run against a known-good input and a known-bad one before it
is trusted — if it cannot produce a pass, it is not a check, it is a constant. Never key on
column position (`$NF`, `awk '{print $3}'`) in kubectl output; read the field by name or by
jsonpath. And a gate that reports absence must distinguish "not there" from "I looked under
the wrong name". See [[proxy-is-not-the-property]].
