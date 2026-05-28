---
key: INFRA-1493
status: filed
assignee: Doke
reporter: Doke
created: 2026-05-28
initiative: onprem-networking
labels: [onprem, networking, cert-manager, irsa, phase0]
issuetype: Sub-task
parent: INFRA-1492
---

# Phase 0 — cert-manager + Route53 IRSA + wildcard cert for `op-dev.usxpress.io`

## Context
Foundation for both HTTPS plane (existing open item) and TCP/SNI ingress (this design). cert-manager with DNS-01 via Route53 needs an IRSA-attached IAM role. The `iaac-route53-zone` trust on the parent AWS account already accepts roles matching `cert-manager-*` from USXpress AWS Org — no network-team turnaround required.

## Scope

**In:**
- IAM role `cert-manager-op-usxpress-dev` in playground AWS account (cluster's account), zone-scoped to `op-dev.usxpress.io` (Route53 hosted zone).
- IRSA OIDC trust against the on-prem cluster's CloudFront OIDC issuer + ServiceAccount `cert-manager-controller` in `cert-manager` namespace.
- cert-manager HelmRelease (or Helm-managed) in `cert-manager` ns with IRSA SA annotation.
- `ClusterIssuer` for Let's Encrypt PROD via DNS-01 against the IAM role.
- Wildcard `Certificate` `*.op-dev.usxpress.io` in `istio-ingress` namespace for gateway use.
- Documentation snippet in `iaac-drafts/onprem-cert-manager/` ready for review.

**Out:**
- Per-namespace backend certs (those land in Phase 2 per service).
- AWS PCA configuration (deferred to ADR — see open question).
- Existing in-cluster cert-manager (if any) — verify before deploying parallel.

## Definition of done
- [ ] IAM role + trust policy committed to `iaac-talos` (or appropriate IaC repo) and applied via Octopus
- [ ] cert-manager pods Running with IRSA SA, no permission errors
- [ ] `ClusterIssuer letsencrypt-prod` Ready=True
- [ ] `Certificate istio-ingress/wildcard-op-dev` Ready=True with valid public-trust chain
- [ ] `openssl s_client -servername foo.op-dev.usxpress.io -connect <worker-ip>:443` returns the wildcard cert chain (once gateway HTTPS listener wired — Phase 1)
- [ ] No degradation to running RW workload (Running=True before/after)

## Suggested approach
1. Inspect cluster for existing cert-manager presence: `kubectl get crd certificates.cert-manager.io`, `kubectl get clusterissuer -A`. If something exists (might from prior Flux work), document and decide replace-or-reuse before proceeding.
2. Author IAM role under `iaac-talos` follow the same pattern as `extd-usxpress-io-op-usxpress-dev` (already shipped). Verify trust against `iaac-route53-zone` wildcard.
3. Author cert-manager HelmRelease under `iaac-talos-flux-platform/infrastructure/cert-manager/` (op-dev branch).
4. Test issuance on a throwaway cert (`test-cert-manager.op-dev.usxpress.io`) before issuing the wildcard.
5. Open separate PR per repo to keep blast radius small.

## Constraints
- TfApply discipline.
- Doesn't depend on HTTPS plane work — actually unblocks it. Run in parallel with other Phase 1 prep.
- Cert-manager rotation typically 60 days for LE; cron-side monitoring needed before declaring done.

## Links
- Parent: [TCP/SNI ingress umbrella] (link after parent filed)
- Design doc: [`docs/designs/tcp-sni-ingress-design.md#phase-0`](https://github.com/damoke012/eks_code/blob/main/docs/designs/tcp-sni-ingress-design.md)
- Route53 trust memory: `onprem_route53_wildcard_trust_discovery`

## Estimate
M — two repos (IAM in iaac-talos + cert-manager in iaac-talos-flux-platform), DNS-01 has a learning curve if first time, but Route53 trust is pre-arranged.
