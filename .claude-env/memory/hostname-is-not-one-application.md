---
name: hostname-is-not-one-application
description: "Repointing a hostname moves every path under it — an Istio VirtualService with no uri match is a catch-all, so RisingWave's Dex issuer and SSO callback at /dex and /auth went to the meta dashboard and login 404'd"
metadata:
  node_type: memory
  type: feedback
---

op-dev, 2026-10-06. `risingwave-dashboard.op-dev.usxpress.io` served the **console**, which
Tim flagged as the wrong name. PR #166 repointed it from `risingwave-console:8020` to
`risingwave-meta:5691`. The UI was correct afterwards and verified by response hash. **SSO
broke.** The console issues to

```
https://risingwave-dashboard.op-dev.usxpress.io/dex/auth?client_id=risingwave-console
   &redirect_uri=…%2Frisingwave-dashboard.op-dev.usxpress.io%2Fauth%2Fsso%2Fcallback
```

so `/dex/*` and `/auth/*` moved to the meta dashboard with `/`, which has no such paths →
**Not Found**. PR #167 reverted it; `/dex/auth` → 200.

**Why:** a VirtualService whose `http:` entry has no `match.uri` is a **catch-all** — one
route carries every path on the host. Repointing the destination relocates every API,
callback and auth endpoint that any client hardcoded. The broken client here was an OIDC
redirect chain: invisible to a reconcile, to `kubectl get vs`, and to any probe of `/`.

**How to apply:** before repointing a hostname, enumerate its **paths** and its
**consumers**, not just what `/` renders.

```
kubectl -n <ns> get vs <name> -o yaml | grep -A5 'match:\|uri:'    # no match = catch-all
kubectl -n <ns> get deploy <app> -o yaml | grep -iE 'issuer|redirect|callback|_url'
```

An issuer URL is a consumer of the hostname and lives in the **application's** config
(`variant-inc/iaac-risingwave-onprem`), never in the routing repo.

**The rename is a sequenced four-step change, not a diff:** move the console's issuer and
callback to the new host → **add** the redirect URI to the shared Entra app registration
(`e112d6ce`, add not replace — QA and prod share it, see
[[rw-dex-entra-shared-app-registration]]) → prove login end to end → then repoint.
Step 2 is not self-service from this repo.

**Killed:** restoring only `/dex` by path-prefix while `/` goes to meta. The callback and
session cookie sit on the console's own host, so the flow would deposit the user on the
meta dashboard. Splitting one app's auth across two backends by path is worse than the name.

Related: [[onprem-ingress-dns-convention]], [[config-can-outrun-the-image]],
[[proxy-is-not-the-property]] (verifying `/` is a proxy for verifying the host).
Note: `wip/rw-dns/STATE.md`.

## ✅ RESOLVED 2026-10-08 — and the resolution is the lesson

`risingwave-dashboard.op-dev.usxpress.io` now serves the meta dashboard
(`cc738d9a03a28c9a`), `risingwave-console.op-dev` serves the console
(`9980ad26c2748234`), and a human signed in on the console hostname at 16:38 UTC.

**The hostname was pinned in config, never in routing.** Three values, found by reading the
live cluster rather than the manifests: the Dex `issuer`, the Entra connector `redirectURI`
(both in `cm/risingwave-console-dex`), and `RCONSOLE_SSO_DEX_ISSUERURL` on the console
Deployment. Plus a fourth outside Kubernetes entirely — the shared Entra app registration
`e112d6ce`, where the new `/dex/callback` was **added**, never replacing the list that also
serves QA and prod ([[rw-dex-entra-shared-app-registration]]).

**The safe order, which is the reusable part.** The console VirtualService already declared
three hosts against one catch-all route, so `/dex/*` was *already* served on the new
hostname. Config first, route last: in between, a user starting at the old hostname is
bounced to the new one and signs in there. There is no window without a working login, and
no flag-day.

**The risk that was real but did not fire:** the console self-registers its OIDC client over
gRPC and Dex stores clients in sqlite on a 129-day-old PVC, so the old callback was a row in
a database, not a manifest. Read the console's startup log for the re-registration line
**before** a human opens a browser — `SSO self-registered OIDC client … (redirect_uri …)`.

**`/dex/auth` → 200 is worthless as a gate.** It returned 200 before the change, during the
broken #166 window, and after. The valid values are Dex's `login successful` line and a human
in a browser ([[adjacent-step-green-signals]]).

Full record: `wip/rw-dns/BASELINE-2026-10-08-before-change-B.md`.

