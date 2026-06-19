
## 2026-06-02 (Tue PM) — Dashboard 503 RCA + codification

- ✅ rw2-dashboard.op-dev.usxpress.io → HTTP 200 from corp VPN (end-to-end validated 5x stability)
- ✅ rw2-sql.op-dev.usxpress.io:4567 → Verification OK (unaffected — TLS PASSTHROUGH)
- ✅ RW CR Running=True, Tim's `risingwave` ns untouched
- 🐛 RCA: MeshConfig had `defaultServiceExportTo`/`defaultVirtualServiceExportTo`/`defaultDestinationRuleExportTo` = `["."]`, scoping every Service to its own namespace. istio-ingressgateway in `istio-ingress` ns saw zero outbound clusters → all HTTP routes 503. rw2-sql worked because TLS PASSTHROUGH bypasses cluster discovery.
- 🛠 Fix: set all three to `["*"]` (Istio chart default).
- 📦 PR [iaac-talos-flux-platform#21](https://github.com/variant-inc/iaac-talos-flux-platform/pull/21) — meshConfig defaults, merged + Flux-reconciled.
- 📦 PR [iaac-risingwave-2#12](https://github.com/variant-inc/iaac-risingwave-2/pull/12) — ambient label removal from RW-2 ns (cluster posture alignment), merged + Flux-reconciled.
- 📋 INFRA-1510 → Done with full RCA comment + PR links.
- 🧠 Memory: `istio_mesh_exportto_rca_jun02.md` (indexed in MEMORY.md).
- ❌ Red herrings ruled out during debugging (don't repeat):
  - Waypoint deployment for risingwave-2 (works only for ambient gateway, not sidecar gateway)
  - ambient label removal alone (necessary cleanup but NOT the blocker)
  - `PILOT_FILTER_GATEWAY_CLUSTER_CONFIG=false`
  - `serviceScopeConfigs` (multicluster-only, irrelevant)
  - Labeling Services with `istio.io/global=true`
- 🐛 Side-discovery: `istio-ca-root-cert` ConfigMap is not auto-distributed to any namespace. Surfaced during waypoint test (CM mount failed). Not blocking today but file followup ticket.
- 🔒 Pending action item (deferred by user): rotate `op-usxpress-dev/risingwave-2/root` in AWS SM — password printed in transcript during diagnostic.

## 2026-06-02 (Tue afternoon) — Round 2 shipped end-to-end

Cluster posture hardened: cert-rotation auto-restart, platform alerting, and ingress lockdown all live.

- ✅ stakater/reloader installed (chart 2.2.12, app v1.4.17), watching CMs+Secrets cluster-wide. ghostunnel-rw2-sql already has the `reloader.stakater.com/auto: "true"` annotation → cert rotation now auto-rolls ghostunnel. (INFRA-1502)
- ✅ PrometheusRule platform-health: 12 alerts across certificates / Flux / ingress / platform-pods / cluster groups. `release=prometheus-stack` label matches the live ruleSelector. (INFRA-1503)
- ✅ CiliumNetworkPolicy `allow-corp-vpn-to-ingressgateway` on istio-ingress: restricts gateway DS ingress to corp VPN (10.11.0.0/19) + worker subnet (10.10.82.0/24) + pod CIDR (10.244.0.0/16) + service CIDR (10.96.0.0/12) on 80/443/4567/5432. Plus probes via host/remote-node and Prometheus scrape on 15020/15090. (INFRA-1496 part 1)
- ✅ CiliumNetworkPolicy `only-from-gateway-or-intrans` on risingwave-2 ns: default-deny ingress with explicit allows for gateway, intra-ns, prometheus, host/remote-node, flux-system, cert-manager, reloader, future risingwave-2-operator-system. (INFRA-1496 part 2)
- 📦 PRs: variant-inc/iaac-talos-flux-platform #22 (reloader) + #23 (chart version fix) + #24 (PrometheusRule) + #25 (gateway CNP); variant-inc/iaac-talos-flux-cluster #8 (reloader Kustomization wiring); variant-inc/iaac-risingwave-2 #13 (RW-2 ns CNP).
- 🧪 Validated end-to-end: dashboard 200, rw2-sql Verification OK, RW CR Running=True, ghostunnel 2/2, Tim's risingwave ns untouched, all 7 gateway pods Ready.
- ⚙️ Gotcha captured: stakater publishes chart and app versions separately (chart 2.2.x → app v1.4.x). Initial draft used app version as chart version → HelmChart resolution failed. Pin chart version, not app version.
- ⚙️ Gotcha captured: `infrastructure/prometheus/` and `iaac-risingwave-2/manifests/op-usxpress-dev/` use explicit kustomize resources lists, not dir-discovery. New files MUST be added to kustomization.yaml or Flux silently skips them.
- ⚙️ Note: Cilium was default-allow before today (zero CNPs). The moment a CNP applies to an endpoint, that endpoint enters default-deny for matched directions. Quick rollback for either CNP: `kubectl delete cnp <name> -n <ns>`.
