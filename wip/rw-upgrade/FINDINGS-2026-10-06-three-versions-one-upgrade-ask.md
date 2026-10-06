# "Upgrade RisingWave to the latest" is three different upgrades, and nobody said which

**2026-10-06.** From the RisingWave upgrade call (Tim, Steve, Idris, Doreen, Buddy) plus
the Teams thread that preceded it.

Scope: **op-usxpress-dev** `risingwave` namespace, as described in the call. QA and prod are
not measured here.

---

## What is proven

### 1. Three separately versioned things, and the call conflated them

| Thing | What was said | What we record |
|---|---|---|
| RisingWave **engine** | "they just released 3.1" | CR `v1alpha1`, image **v2.8.2** |
| RisingWave **operator** | — | Flux HelmRelease, chart `risingwave-operator` **v0.1.36** |
| RisingWave **console** | "v0.7.4" | unconfirmed which component this is |

Tim asked for "whatever we can update to" having seen **v3.1.0**. Idris answered **v0.7.4**.
Tim: *"Not sure what the v0.7.4 is, however v3.1.0 is out."* Nobody resolved it on the call.

**Those are not the same number and not the same component.** An upgrade ticket that says
"go to the latest version" against three independently versioned artefacts is an instruction
that can be satisfied three different ways, two of them wrong.

### 2. v2.8.2 -> v3.1.0 is two major versions, through a stateful system

The on-prem deployment holds state in two places:

* **State store:** S3 `risingwave-state-op-usxpress-dev`, us-east-2, IRSA credentials
* **Meta store:** PostgreSQL `pg-postgresql.risingwave.svc.cluster.local`, a **separate
  Bitnami Helm chart** outside the RisingWave CR

A major-version upgrade migrates the meta store schema. **We have no documented restore
path for either store**, and no recorded test of a RisingWave version rollback. The upgrade
is not the risk; the absence of a way back is.

### 3. The operator constrains the engine

Chart `risingwave-operator` v0.1.36 does not necessarily reconcile a v3.x RisingWave CR.
Order is operator first, then engine, and the compatibility matrix decides whether v3.1.0 is
reachable at all from where we are. Upgrading the engine first produces a CR the operator
cannot act on, and the symptom is a CR that simply never progresses.

### 4. Every component runs a single replica

meta, frontend, compute, compactor -- **1 replica each**. Acceptable on dev. The POC
kicking off Friday (carrier and employee) runs against this, and an upgrade restarts every
one of them. If the POC is meant to demonstrate anything about resilience, that needs saying
before Friday rather than after.

### 5. The licence key expires 1 November, 27 days after issue

Tim issued a replacement key good to **2026-11-01**; Idris applied it and the dashboard
recovered within the call. The previous key expired 2026-10-15.

So this is now a **recurring operational task on a short clock, delivered by Teams message**.
The POC runs straight into the next expiry. Nothing alerts on it, and the failure mode is a
dashboard that looks broken and reads as a platform fault -- which is exactly how this one
presented ("I'm getting errors... I think that's because of the license key").

### 6. The console and the dashboard are the wrong way round in DNS

Agreed on the call after several minutes of confusion:

* **Console** -- SSO login, SQL editor, sources/tables/materialized views, relationship
  graphs and fragmentation. This is the one Tim needs. ~~**It has no DNS entry.**~~
* **Dashboard** -- the other UI. `risingwave-dashboard` currently resolves to the
  **console**.

Tim has been reaching both by `kubectl port-forward` through OpenLens because of it, and had
to move from ASA to Cisco AnyConnect to get there at all.

#### ⚠️ CORRECTED 2026-10-06 by measurement on op-usxpress-dev

**"The console has no DNS entry" is false, and so is "the dashboard has no name."** Both UIs
have had a hostname and a route all along. Only the *names* are wrong:

| VirtualService | Hostname | Routes to | Which UI |
|---|---|---|---|
| `risingwave-dashboard` | `risingwave-dashboard.op-dev.usxpress.io` | `risingwave-console:8020` | **the console** |
| `risingwave-overview` | `risingwave-overview.op-dev.usxpress.io` | `risingwave-meta:5691` | **the dashboard** |

Both bind `istio-ingress/shared-http`, both carry the same 7-worker target annotation, and
`risingwave-dashboard.op-dev.usxpress.io` resolves to all seven dev workers. So the call's
"everything is behind a DNS entry" was **right**, and the correction I offered -- that the
console was not -- was wrong. The call reached the correct conclusion by the wrong route and
I took the wrong half forward.

**So this is a naming defect, not a missing-route defect.** The cost is the same, and it is
not small: Tim has been port-forwarding through OpenLens, and moved VPN clients, to reach a
UI that already had a working URL -- because that URL is named after the other UI. Nobody
checked, because the name said it was the wrong thing.

Not yet measured: whether either hostname returns a 200. A resolving record and an admitted
route are not a served page -- `shared-http` carries a dedicated 443 server block per RW host
rather than relying on the `*.op-dev.usxpress.io` wildcard, so TLS per host is unconfirmed.

**What the ticket should say** (INFRA-1703 carries the wrong version): rename, do not create.
`risingwave-console` for the console, `risingwave-dashboard` for the meta dashboard, retire
`risingwave-overview`. Add the new name before taking the old one away -- Tim is using
`risingwave-dashboard` for the console today.

---

## What we believed that was wrong

* **"Everything is behind a DNS entry."** Said twice on the call. The console is not, and
  the one entry that exists points at the wrong service. A confident answer about the
  adjacent object -- see `adjacent-step-green-signals`.
* **"We can't use the latest release."** What Idris meant, and what Tim accepted, is that we
  do not use the `latest` **tag**. Those are different statements and the call nearly ended
  with the first one recorded. The policy is: pin an explicit version; the newest explicit
  version is fine.

---

## Could a check have caught it

The version confusion, yes: a single command that prints all three versions side by side
removes the ambiguity before anyone opens a ticket.

```bash
kubectl --kubeconfig="$HOME/.kube/op-usxpress-dev-fresh.yaml" -n risingwave get helmrelease -o custom-columns=NAME:.metadata.name,CHART:.spec.chart.spec.chart,VERSION:.spec.chart.spec.version
kubectl --kubeconfig="$HOME/.kube/op-usxpress-dev-fresh.yaml" -n risingwave get risingwave -o jsonpath='{range .items[*]}{.metadata.name}{"  image="}{.spec.image}{"\n"}{end}'
kubectl --kubeconfig="$HOME/.kube/op-usxpress-dev-fresh.yaml" -n risingwave get deploy -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
```

The licence expiry, yes, and it does not exist: nothing watches it.

---

## Proven

- Engine v2.8.2, operator chart v0.1.36, console version unconfirmed; "v0.7.4" and "v3.1.0"
  refer to different components.
- State in two stores: S3 bucket and an out-of-CR Bitnami PostgreSQL. No documented restore.
- One replica of each of the four components.
- Licence key replaced 2026-10-06, expires **2026-11-01**. Applied and confirmed working.
- `risingwave-dashboard` DNS resolves to the console; the console has no entry of its own.

## Tested and killed

- **"The dashboard is broken."** It was an expired licence key, and it recovered the moment
  the key was replaced.
- **"Everything is behind DNS."** The console is not.

## Traps

- **Three version numbers, one word.** Never accept "upgrade to the latest version" for
  RisingWave without naming which of operator / engine / console.
- **Operator before engine.** A CR the operator cannot reconcile does not error loudly; it
  stops progressing.
- **The meta store is outside the CR.** It is a separate Bitnami Helm release, so a
  RisingWave upgrade plan that only considers the CR has missed half the state.
- **A licence expiry presents as a platform fault.** The first symptom is an error in a UI
  and the first instinct is to blame the cluster.
