---
name: onprem-egress-to-partner-apis-works
description: "PROVEN 2026-10-20 from a pod on op-usxpress-qa: both Knight-Swift endpoints answer HTTP 405 with tls_verify=0 — on-prem pods reach external HTTPS partners and trust public CAs with the default bundle. Grafana is the op-qa pod that carries curl"
metadata:
  type: project
---

**Measured from inside the cluster**, not from a workstation — the distinction that mattered,
because Idris's earlier test was from a laptop and could not speak for a pod.

```
grafana/grafana-7996f6d86f-dpchf on op-usxpress-qa, HEAD request:

https://pricing-tools-qa.swifttrans.com/api/pricingtools/incumbentDataUpdate
  code=405  tls_verify=0  ip=199.79.30.140  t=1.02s
https://pricing-tools.swifttrans.com/api/pricingtools/incumbentDataUpdate
  code=405  tls_verify=0  ip=199.79.30.130  t=0.34s
```

**What each field proves:**

* **405 Method Not Allowed is the pass.** It means their *application* answered and refused a
  HEAD on a POST-only route — so DNS, routing, the firewall, the TLS handshake, HTTP and their
  app layer all worked. A 2xx was never possible without credentials; **a timeout would have
  been the failure**, and reading 405 as one is the trap.
* **`tls_verify=0`** — the pod trusts the partner's chain with the image's **default** CA
  bundle. No custom CA work is needed for Knight-Swift. (The SQL Servers are a separate
  question: they set `TrustServerCertificate=false` and the cloud pod carries a
  `custom-ca-bundle` volume.)
* **The addresses match the workstation test exactly** (199.79.30.140 / .130), so on-prem DNS
  resolves these names the same way the corporate network does.

⚠️ **This proves the network path, not the application's calls.** The OAuth token endpoint
`login.microsoftonline.com` is a different host and was not tested, and a real call needs the
client credentials. Measured on **op-qa**; op-dev shares the /24 but has not been tested.

⚠️ **`HEAD`, never `POST`.** The route is `incumbentDataUpdate` — a POST could write something
on a partner's production system. Use `curl -I` for reachability.

## Which on-prem pod can run a probe

Most platform images are minimal and this costs a round trip every time:

| Pod on op-qa | curl |
|---|---|
| **`grafana/grafana`** | ✅ **the one to use** |
| `argocd/argocd-repo-server` | ❌ |
| `istio-ingress/istio-ingressgateway` | ❌ no curl, no getent |
| cert-manager, external-secrets, flux controllers | ❌ distroless |

And `app-risingwave` on **op-dev is empty**, so a probe aimed there finds no pod at all.

⚠️ A `kubectl exec` may print `websocket.go:296] Unknown stream id 1, discarding message`
alongside correct output. That is the exec transport, **not a finding**
([[transport-failure-not-a-verdict]]).

Related: [[atlas-privatelink-may-not-reach-onprem]] (the dependency that is *not* reachable),
[[onprem-ingress-dns-convention]].
