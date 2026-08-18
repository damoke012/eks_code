# Exposing a service on-prem

This template deliberately stops at a `ClusterIP` Service. DNS, TLS and ingress are
a platform concern with an existing chart — `platform-app-expose` (INFRA-1527) —
which produces the Istio VirtualService, an optional cert-manager Certificate and
an optional CiliumNetworkPolicy from a hostname and a service reference.

Ask platform to onboard your service to it rather than hand-authoring a
VirtualService. Hand-authored ingress is how 157 apps end up with 157 slightly
different opinions about TLS.
