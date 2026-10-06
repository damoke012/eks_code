# RisingWave on-prem DNS — op-usxpress-dev

**Status 2026-10-06: there is no DNS defect. Both UIs are served and reachable.**
What exists is a naming defect, and it cost Tim weeks of port-forwarding.

## Measured on op-usxpress-dev (10.10.82.50), 2026-10-06

| Hostname | Routes to | Which UI | http | https |
|---|---|---|---|---|
| `risingwave-dashboard.op-dev.usxpress.io` | `risingwave-console:8020` | **console** | 200 | 200 |
| `risingwave-overview.op-dev.usxpress.io` | `risingwave-meta:5691` | **dashboard** | 200 | 200 |

Both resolve to all seven dev workers
(`.21 .22 .26 .27 .28 .178 .180`), both bind `istio-ingress/shared-http`.

`shared-http` servers: `*.op-dev.usxpress.io` on 80; `*.op-dev.usxpress.io` on 443
(`wildcard-op-dev-tls`); `*.brands…`; plus a **redundant** dedicated 443 block for each of
the two RisingWave hosts with its own cert secret. The wildcard already covers them, so a
new `*.op-dev.usxpress.io` hostname needs **no Gateway change and no Certificate** — a
VirtualService alone is enough.

## What was wrong, and whose claim it was

* The call concluded "the console has no DNS entry." **False** — it has had one since Phase 1,
  under the name `risingwave-dashboard`.
* I then repeated it and wrote it into INFRA-1703 as an acceptance criterion. Worse than
  repeating it: I turned a verbal muddle into a work item that would have had someone build a
  route that already exists.
* `risingwave-meta` being headless was raised as a possible blocker. **Not a blocker** — Istio
  routes to headless Services per-pod, and `risingwave-overview` has been doing exactly that.

Nobody checked the URL because the name said it was the other UI. That is the whole failure.

## Change: additive only

`wip/rw-dns/virtualservice-risingwave-console.yaml` adds
`risingwave-console.op-dev.usxpress.io` → `risingwave-console:8020`.

Both names then serve the console. Nothing is taken away, nothing Tim uses moves.

**Deferred, and only after Tim confirms he is off the old name:** repoint
`risingwave-dashboard` → `risingwave-meta:5691` and fold `risingwave-overview` into it.
That step removes a working URL from a user, so it waits for his word, not ours
([[promotion-order-qa2-dev-qa-prod]]).

## Gates

* `risingwave` on op-dev is **Tim's namespace** — his nod before merge, not after.
* `iaac-risingwave-onprem` tracks `branch: main` at 5m on every cluster, so **merging is
  deploying**. Living under `manifests/op-usxpress-dev/` is what keeps this off QA and prod.
* That directory **enumerates** its resources — the new filename must be added to
  `kustomization.yaml` or it applies to nothing, silently.

## Proven / killed / traps

**Proven.** Both RisingWave UIs are served over http and https on op-dev and resolve to all
seven workers. The wildcard 443 server covers any new `*.op-dev.usxpress.io` host.

**Killed.** "The console has no DNS entry." "The dashboard has no name." "A headless meta
Service blocks an Istio route." "This needs a new Certificate and a Gateway edit."

**Traps.**
1. A resolving record is not a served page, and an admitted route is not either. Only the
   `curl` settled it — and it is what turned a three-object change into a one-object change.
2. **A name is an assertion, and nobody re-checks an assertion that is written down.** The
   route was correct and documented; the label on it was wrong, so the correct thing was
   invisible for weeks. See [[proxy-is-not-the-property]].
3. A meeting that reaches the right conclusion by the wrong argument is indistinguishable
   from one that reached the wrong conclusion — until someone measures. I corrected the call
   towards the wrong answer, confidently, from the same unmeasured ground they were on.

---

## ✅ SHIPPED AND VERIFIED 2026-10-06

PR **#163** merged to `op-dev` of `variant-inc/iaac-talos-flux-platform` —
`infrastructure/risingwave-routes/virtualservice-risingwave-console.yaml` plus the
kustomization line. **Note the repo: the platform repo, NOT `iaac-risingwave-onprem`.** That
repo's `manifests/op-usxpress-dev/` holds only the `*-ext.yaml` NodePort Services; every
VirtualService lives in the platform repo's `risingwave-routes` directory. The first attempt
targeted the wrong repo and the file listing caught it.

Verified by **content**, not by name:

```
risingwave-console     http=200 verify=0 9980ad26c2748234
risingwave-dashboard   http=200 verify=0 9980ad26c2748234   <- identical: both the console
risingwave-overview    http=200 verify=0 cc738d9a03a28c9a   <- differs: the meta dashboard
```

Comparing response hashes proves the routing without parsing a single page. Two hostnames
that must serve the same thing, one that must not — three numbers settle it.

**`verify=0` on the new host confirms the untested assumption**: `shared-http`'s
`*.op-dev.usxpress.io` 443 server with `wildcard-op-dev-tls` covers a brand-new hostname, so
no Certificate and no Gateway edit were needed. The per-host certs for dashboard and overview
are redundant with it.

### Trap: the local resolver cached NXDOMAIN

external-dns created the record **seconds** after the Kustomization applied
(`CREATE risingwave-console.op-dev.usxpress.io A`, zone `Z0658284PVIFD4Q8I9PO`), and
`dig @8.8.8.8` returned all seven worker IPs immediately. But `getent hosts` kept saying no
for five minutes, because the name had been queried repeatedly earlier in the day while it
genuinely did not exist, and the negative answer was cached locally.

**A new DNS record looks identical to a broken one from a machine that asked too early.**
Query an authoritative or public resolver (`dig +short <name> @8.8.8.8`) before concluding
external-dns failed, and test the route itself with
`curl --resolve <host>:443:<node-ip>`, which bypasses DNS entirely. From WSL the flush is
`cmd.exe /c ipconfig /flushdns`.

### Still open

Repointing `risingwave-dashboard` at the meta dashboard and retiring `risingwave-overview`.
That removes a URL in use, so it waits until Tim has moved to `risingwave-console`.
