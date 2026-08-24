# 2026-08-24 — Argo CD had no URL on any cluster, and dev had no route

**Scope: op-usxpress-dev (10.10.82.50) and op-usxpress-qa (10.10.82.51), measured
2026-08-24. op-usxpress-prod was NOT measured — no kubeconfig on this machine reaches
10.10.82.52.**

## Proven

`configs.cm.url` was **unset on both branches**, so `argocd-cm` carried the chart default
`https://argocd.example.com`. Argo builds every link it emits — and, once SSO exists, its
OIDC `redirect_uri` — from that value. No provider could have been configured until it was
right. Fixed on `op-dev` (PR #126) and `op-qa` (PR #127).

Dev had **no VirtualService and no Ingress at all** in the `argocd` namespace: ClusterIP plus
`server.insecure: true`, reachable only by port-forward. QA already had one, from INFRA-1622.

Dev's route is now live and **verified end to end**:

```
external-dns: "Desired change: CREATE argocd.op-dev.usxpress.io A"
              zoneID=/hostedzone/Z0658284PVIFD4Q8I9PO  21:46:55Z
dig +short argocd.op-dev.usxpress.io @1.1.1.1   -> 7 IPs
curl --resolve argocd.op-dev.usxpress.io:443:10.10.82.21 https://argocd.op-dev.usxpress.io/
                                                -> 200
```

The `--resolve` form is the one that proves something. It sends the real SNI to a real
ingress node, exercising the gateway host match, `wildcard-op-dev-tls` and the route to
`argocd-server:80`, while bypassing the resolver entirely. A plain `dig` had returned nothing
for ten minutes because an earlier query — run before the merge, when the name genuinely did
not exist — left an NXDOMAIN in the local cache. **Querying a name before you create it
poisons your own verification.**

## Two things that are NOT uniform across clusters

Both were found by asserting a supposed invariant and having it fail.

**1. Who owns `argocd-secret`.**

| | `configs.secret` | owner |
|---|---|---|
| op-dev | `createSecret: false` | pre-existing secret, preserved |
| op-qa  | absent | Helm |

Dev's Argo adopted a 49-day-old raw install whose `argocd-secret` already held
`server.secretkey` and TLS; letting Helm create it would regenerate the key and end every
session. QA was greenfield. **This decides how an OIDC `clientSecret` gets in** — merged by
ExternalSecret on dev (as `admin.password` already is), contended with Helm on QA. Same
feature, two mechanics.

**2. What `external-dns.alpha.kubernetes.io/target` should contain.**

| | ingressgateway pods | target list |
|---|---|---|
| op-dev | 7, on all 7 workers | all 7 worker IPs |
| op-qa  | 10, on all 10 workers | 3 IPs — the `platform` workers only |

There is **no rule** to generalise. Derive the list from a route already serving on the same
cluster, and check that route's hostname belongs to that cluster before trusting it.

## ⚠️ op-qa is live-serving a dev hostname

```
NS        NAME      HOSTS
argocd    argocd    [argocd.op-qa.usxpress.io]
grafana   grafana   [grafana.op-dev.usxpress.io]   <-- on the QA cluster
```

Dev serves that same name. **Two clusters claim one DNS record**, both running external-dns
against zone `usxpress.io`. As of 2026-08-24 21:50 it resolves to dev's seven nodes, so
whichever external-dns wrote last is currently winning. Someone opening dev's Grafana URL can
land on QA's.

`op-prod`'s branch carries the same copied file — `grafana.op-dev.usxpress.io` with dev's
seven target IPs — plus `credentialName: wildcard-op-qa-tls` on its shared gateway. **Not
verified live**: nothing under `~/.kube` serves 10.10.82.52, and today's prod checks were
break-glass and were not persisted. Branch content only.

This is `manifests-copied-across-branches` at the ingress layer. It needs its own ticket and
it outranks Argo SSO.

## Still to do for SSO (INFRA-1639)

1. ~~a reachable hostname~~ — done on dev, already existed on QA
2. ~~`configs.cm.url`~~ — PRs #126 / #127
3. **provider** — undecided. `dex.enabled: false` on QA, so Dex means installing a component;
   `oidc.config` straight to an IdP does not. Entra is blocked on Azure access.
4. **`policy.csv` + `policy.default`** — both empty. A successful SSO login currently lands
   with **zero permissions**, which presents as a broken login when it is RBAC.

Also unresolved: `argocd-server` reads `url` at startup for OIDC purposes. If the Helm upgrade
did not restart the pod, the redirect base may be stale when step 3 lands. Check pod age then.

---

**Proven:** `configs.cm.url` was unset on op-dev and op-qa on 2026-08-24 and defaulted to
`https://argocd.example.com`; dev had no VirtualService or Ingress in `argocd`; dev's new
route returns 200 via `--resolve` against 10.10.82.21 with SNI `argocd.op-dev.usxpress.io`;
external-dns created the A record in zone Z0658284PVIFD4Q8I9PO at 21:46:55Z; op-qa's Grafana
VirtualService claims `grafana.op-dev.usxpress.io` on the live QA cluster.
**Tested and killed:** "the DNS targets are the worker IPs" — true on dev (7/7), false on QA
(3 of 13); "`createSecret: false` is the house pattern" — it is dev's history, absent on QA;
"prod's ingress is misconfigured" — NOT established, prod was never reached, branch content
only; "a plain dig verifies the route" — it returned nothing for ten minutes on a name that
worked, because of a negative cache I created myself.
**Traps:** querying a hostname before creating it caches the NXDOMAIN and breaks your own
verification; Flux reporting the VirtualService Ready proves the object exists, not that
external-dns wrote a record; `kubectl get gateway` resolves to `gateway.networking.k8s.io`,
not Istio's, and returns a misleading NotFound; an assertion built from the one cluster you
can see encodes that cluster's history as a rule.
