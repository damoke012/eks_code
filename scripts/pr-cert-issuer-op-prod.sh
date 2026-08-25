#!/usr/bin/env bash
# INFRA-1663 -- op-prod's ACME issuers only solve for QA's DNS zone.
#
# Read from the live prod cluster 2026-08-25:
#
#   clusterissuer/letsencrypt-prod
#     solvers[0].selector.dnsZones = ["op-qa.usxpress.io"]
#     solvers[0].dns01.route53.role = arn:aws:iam::155768531003:role/iaac-route53-zone
#
# So an Order for *.op-prod.usxpress.io matches no solver at all, and cert-manager
# creates ZERO Challenges:
#
#   Failed to determine a valid solver configuration for the set of domains on the
#   Order: no configured challenge solvers can be used for this challenge
#
# This is the second half of the prod ingress breakage. The first half is that
# cert-manager has no IRSA credentials -- see the PR body -- and is NOT fixed here,
# because it is a pod-recreation, not a manifest change.
#
#   scripts/pr-cert-issuer-op-prod.sh
#   scripts/pr-cert-issuer-op-prod.sh --push
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUSH="${1:-}"
BR=op-prod
REPO="${REPO:-$HOME/pr-work/iaac-talos-flux-platform}"
[ -d "$REPO/.git" ] || { echo "!! not a git repo: $REPO" >&2; exit 2; }

cd "$REPO"
git fetch -q origin
TOPIC="infra-1663-cert-issuer-$BR"
git checkout -q HEAD -- infrastructure 2>/dev/null || true
git clean -qfd infrastructure 2>/dev/null || true
git checkout -q -B "$TOPIC" "origin/$BR"
git checkout -q "origin/$BR" -- infrastructure
git clean -qfd infrastructure

python3 - <<'PY'
import glob, yaml
changed = []
for p in sorted(glob.glob("infrastructure/cert-manager-issuers/letsencrypt-*.yaml")):
    txt = open(p).read()
    if "op-qa" not in txt:
        print("   %s: no op-qa literal, leaving alone" % p); continue
    open(p, "w").write(txt.replace("op-qa", "op-prod"))
    changed.append(p)
assert changed, "no issuer carried an op-qa zone -- already fixed?"

for p in changed:
    d = yaml.safe_load(open(p))
    assert d["kind"] in ("ClusterIssuer", "Issuer"), d["kind"]
    solvers = d["spec"]["acme"]["solvers"]
    assert solvers, p
    for s in solvers:
        zones = (s.get("selector") or {}).get("dnsZones") or []
        for z in zones:
            assert "op-qa" not in z, z
            assert z.endswith("op-prod.usxpress.io"), z
        r53 = (s.get("dns01") or {}).get("route53") or {}
        # The cross-account role lives in the network account and is NOT
        # per-cluster; rewriting it would break the delegation.
        if r53.get("role"):
            assert "155768531003" in r53["role"], \
                "the route53 role was rewritten -- it is shared, not per-cluster: %s" % r53["role"]
    print("   %s -> zones now op-prod, route53 role untouched" % p)
PY

echo
git --no-pager diff -- infrastructure/cert-manager-issuers
[ "$PUSH" = "--push" ] || { echo; echo "   DRY RUN -- re-run with --push"; exit 0; }

BODY=$(mktemp); trap 'rm -f "$BODY"' EXIT
cat > "$BODY" <<'MD'
op-prod's ACME issuers only solve for QA's DNS zone:

```
clusterissuer/letsencrypt-prod
  solvers[0].selector.dnsZones = ["op-qa.usxpress.io"]
```

An Order for `*.op-prod.usxpress.io` therefore matches no solver and cert-manager
creates **zero** Challenges:

```
Failed to determine a valid solver configuration for the set of domains on the
Order: no configured challenge solvers can be used for this challenge
```

The cross-account `iaac-route53-zone` role is left untouched — it lives in the
network account (155768531003) and is shared, not per-cluster.

### This is only half the breakage

cert-manager on op-prod has **no IRSA credentials**. Its ServiceAccount carries the
correct annotation (`arn:aws:iam::937464026810:role/cert-manager-op-usxpress-prod`),
but the container's env has no `AWS_ROLE_ARN` or `AWS_WEB_IDENTITY_TOKEN_FILE`, so
the SDK falls back to EC2 instance metadata — which does not exist on bare-metal
Talos:

```
error instantiating route53 challenge solver: unable to assume role:
no EC2 IMDS role found ... ec2imds: GetMetadata, context deadline exceeded
```

pod-identity-webhook is healthy and injecting correctly for external-dns,
external-secrets, velero, etcd-backup and ecr-credentials. cert-manager is the only
workload missing it, because injection happens at **pod creation** and that pod is
27 days old — older than the annotation or the webhook.

That half is fixed by recreating the pod, not by this PR:

```
kubectl -n cert-manager rollout restart deploy cert-manager
```

Both halves are needed. Until then `istio-ingress` never goes Ready, and `grafana`
is blocked behind it — which has been the state of this cluster since it came up.
MD
git add infrastructure/cert-manager-issuers
git commit -qm "INFRA-1663: op-prod ACME issuers solve only for QA's DNS zone

An Order for *.op-prod.usxpress.io matched no solver, so cert-manager created no
Challenges at all. The shared cross-account route53 role is left untouched."
git push -q -u origin "$TOPIC"
gh pr create --base "$BR" --head "$TOPIC" \
  --title "INFRA-1663: op-prod's ACME issuers only solve for op-qa's DNS zone" --body-file "$BODY"
