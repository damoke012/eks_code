# external-dns IaC — staging artifacts (op-usxpress-dev) — piece 2 of 3

Drafted 2026-05-13 in codespace. This is **piece 2** in the post-PTO networking plan
(piece 1 = istio-ingressgateway, piece 3 = cert-manager public ClusterIssuer).
See [steve_duck_networking_message_draft_may13.md](../steve_duck_networking_message_draft_may13.md)
for the strategic frame and `memory/onprem_networking_gap_may13.md` for the full plan.

Tracked by **ONPREM-25** (local planning doc; not yet filed in Jira).

## What this deploys

A second on-prem external-dns deployment that mirrors cloud's `extd-usxpress-io`
pattern. Watches Istio `Gateway` resources, writes records to Route53 zone
`usxpress.io`, uses DynamoDB as the registry (instead of TXT records).

## Cross-account architecture (mirrors cloud)

```
op-usxpress-dev cluster (k8s in USX-Dev 700736442855)
  └─ external-dns pod (SA extd-usxpress-io, IRSA-bound to)
       └─ aws_iam_role op-usxpress-dev-extd-usxpress-io  (in USX-Dev, this artifact provisions)
            └─ sts:AssumeRole  →
                 arn:aws:iam::155768531003:role/iaac-route53-zone  (in Infrastructure-Networking,
                   network-team owned, EXISTS already — we add a trust principal)
                      └─ Route53 writes + DynamoDB registry writes (usxpress.io zone, shared with cloud)
```

## Files

| File | Destination | Owner |
|---|---|---|
| `infrastructure/external-dns/namespace.yaml` | `iaac-talos-flux-platform/op-dev` | platform |
| `infrastructure/external-dns/repository.yaml` | `iaac-talos-flux-platform/op-dev` | platform |
| `infrastructure/external-dns/release.yaml` | `iaac-talos-flux-platform/op-dev` | platform |
| `cluster-kustomization-snippet.yaml` | append into `iaac-talos-flux-cluster/master` `infra.yaml` | platform |
| `iam/extd-usxpress-io-role.tf` | append into `iaac-talos/deploy/terraform/modules/irsa/main.tf` | platform |
| `iam/extd-usxpress-io-output.tf` | append into `iaac-talos/deploy/terraform/modules/irsa/outputs.tf` | platform |
| `iam/iaac-route53-zone-trust-patch.md` | reference — network team will apply on their side | network team |
| `network-team-ask-trust-extension.md` | send to network team | (us → them) |
| `RUNBOOK.md` | reference — full deploy + rollback | platform |

## Dependencies

| Dep | State | Blocks deploy? |
|---|---|---|
| ~~Network-team trust patch on `iaac-route53-zone`~~ | **NOT NEEDED** — verified 2026-05-18, existing trust uses wildcard `extd-usxpress-io-*` | — |
| `extd-usxpress-io-op-usxpress-dev` IAM role created via terraform apply on `iaac-talos` | NOT YET | **YES**: HelmRelease will start but pod can't authenticate |
| Piece 1 (istio-ingressgateway) live | (in flight) | NO — external-dns idles gracefully if no Gateways exist |
| Existing on-prem IRSA (CloudFront OIDC) | DONE | — |

**Why no trust patch is needed**: the trust policy on `iaac-route53-zone`
already permits any role in the USXpress AWS Org matching `extd-usxpress-io-*`
to assume. Our source role is named `extd-usxpress-io-op-usxpress-dev` —
matches the pattern. See `network-team-ask-trust-extension.md` for the actual
existing trust policy and the discovery story.

## Order of operations

1. **Apply Terraform** (`iaac-talos`) to create the source role
2. **Send `network-team-ask-trust-extension.md` to network team** — wait for confirmation
3. **Verify cross-account AssumeRole** works from WSL (see ask doc § Verification)
4. **Commit + push Flux manifests** (platform + cluster repos)
5. **Watch reconcile + pod logs**: external-dns should start, find Gateways, write records
6. **Test resolution**: `dig api.brands.dev.usxpress.io` from VPN → expect worker IP

Details in `RUNBOOK.md`.

## What this does NOT do

- Doesn't decide DNS naming convention for new on-prem apps — open question
  (kept in step 7 of RUNBOOK; flagged in ONPREM-25 AC).
- Doesn't deploy HTTPS — piece 3 (cert-manager ClusterIssuer) handles TLS certs.
- Doesn't touch cloud's `extd-usxpress-io` deployment in iaac-eks. Cloud keeps
  writing records for cloud-side services; we write records for on-prem-side ones.
  Registry collision is prevented by unique `txtOwnerId`.

## Key design choices

| Choice | Why |
|---|---|
| `txtOwnerId: iaac-talos/us-east-2/op-usxpress-dev` | Differentiates on-prem from cloud (`iaac-eks/us-east-2/usxpress-dev`) in the shared DynamoDB registry. Without this, both deployments would fight over the same record entries. |
| Same target role `iaac-route53-zone` | Single ownership boundary; same operational pattern cloud already uses. Don't duplicate the Route53/DynamoDB IAM. |
| `sources: [istio-gateway]` only | We're not using k8s Ingress or Service annotations — Istio Gateway is the single source of truth. Matches cloud. |
| Chart version pinned `1.20.0` | Matches cloud exactly. Easier upgrade story when cloud bumps. |
| `policy: sync` | Records get deleted when Gateway is deleted (vs `upsert-only` which is safer but leaves stale records). Cloud uses sync; we match. |
| `registry: dynamodb` | TXT-record registry has scale + permission issues at high record counts. DynamoDB cleaner. Cloud uses it. |
| Drop cloud's `nodeSelector: iaac=true` + `arm64` + `iaac` taint tolerations | On-prem workers are AMD64, no `iaac` taint. Cloud-only fields would prevent scheduling. |
