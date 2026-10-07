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
