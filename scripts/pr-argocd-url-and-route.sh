#!/usr/bin/env bash
# INFRA-1639 step 1+2 -- give Argo CD a real URL.
#
#   op-dev : add infrastructure/argocd/virtualservice-argocd.yaml + wire it in,
#            and set configs.cm.url
#   op-qa  : set configs.cm.url only (its VirtualService already exists)
#
# WHY url MATTERS BEYOND SSO: argocd-cm.url is the base Argo uses to build its
# OIDC redirect_uri and every link it emits. It is currently the chart default
# `https://argocd.example.com` on BOTH branches -- verified 2026-08-24 by
# grepping op-dev and op-qa helmreleases for `url`, which returned nothing.
# No SSO provider can be configured until this is right.
#
# BUILT FROM THE BRANCH (CLAUDE.md rule 7). Never from wip/.
#
#   scripts/pr-argocd-url-and-route.sh                 # dry run, prints the diff
#   scripts/pr-argocd-url-and-route.sh --only op-dev
#   scripts/pr-argocd-url-and-route.sh --push
set -euo pipefail

# NOTE ON DNS TARGETS: there is no single rule. op-dev targets all 7 workers;
# op-qa targets only its 3 platform workers out of 13, while its ingressgateway
# runs on all 10. So the list is DERIVED from a route already serving on the same
# cluster, never generalised from another one -- and the source route's hostname
# is checked against the branch first, because on 2026-08-24 op-qa was found
# live-serving grafana.op-dev.usxpress.io and op-prod's branch carries the same
# copied file. A copied route is not a valid source of truth.

REPO="${REPO:-$HOME/pr-work/iaac-talos-flux-platform}"
PUSH="no"; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --push) PUSH="yes"; shift ;;
    --only) ONLY="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -d "$REPO/.git" ] || { echo "!! not a git repo: $REPO" >&2; exit 2; }
cd "$REPO"
git fetch origin

# Restore the one directory this script writes. Runs before every checkout and
# on any exit: `checkout -B` REFUSES on a dirty worktree, so a crash mid-branch
# (op-qa's KeyError on 2026-08-24) otherwise blocks every subsequent run,
# including the branch that had already succeeded.
clean_argocd() {
  git checkout -q HEAD -- infrastructure/argocd 2>/dev/null || true
  git clean -qfd infrastructure/argocd 2>/dev/null || true
}
trap clean_argocd EXIT
clean_argocd

BRANCHES="op-dev op-qa"
[ -z "$ONLY" ] || BRANCHES="$ONLY"

for BR in $BRANCHES; do
  case "$BR" in
    op-dev)  SUFFIX="op-dev.usxpress.io" ;;
    op-qa)   SUFFIX="op-qa.usxpress.io" ;;
    op-prod) echo "!! op-prod is excluded: its branch carries op-dev hostnames and wildcard-op-qa-tls," >&2
             echo "   and no kubeconfig reaches 10.10.82.52 to verify. See INFRA-1663." >&2; exit 2 ;;
    *) echo "!! unknown branch $BR" >&2; exit 2 ;;
  esac
  HOST="argocd.$SUFFIX"
  TOPIC="infra-1639-argocd-url-$BR"

  echo
  echo "################ $BR -> $HOST ################"
  clean_argocd
  git checkout -q -B "$TOPIC" "origin/$BR"
  # `checkout -B` CARRIES local modifications across rather than discarding them,
  # so an aborted run leaves its own edits behind and the next run finds them,
  # takes every "already present" path, and asserts against its own output.
  git checkout -q "origin/$BR" -- infrastructure/argocd
  git clean -qfd infrastructure/argocd

  # ---- 1. configs.cm.url (both branches) ----------------------------------
  HR="infrastructure/argocd/helmrelease.yaml"
  [ -f "$HR" ] || { echo "!! $HR missing on $BR" >&2; exit 1; }
  if grep -qE '^\s+url: ' "$HR"; then
    echo "   url: already present, leaving alone"
  else
    [ "$(grep -cE '^      cm:$' "$HR")" -eq 1 ] \
      || { echo "!! expected exactly one '      cm:' line in $HR" >&2; exit 1; }
    python3 - "$HR" "$HOST" <<'PY1'
import sys
path, host = sys.argv[1], sys.argv[2]
lines = open(path).readlines()
out, done = [], False
for ln in lines:
    out.append(ln)
    if not done and ln.rstrip("\n") == "      cm:":
        out.append("        # INFRA-1639 -- the base URL Argo builds every link and, when SSO is\n")
        out.append("        # configured, its OIDC redirect_uri from. Left unset it is the chart\n")
        out.append("        # default https://argocd.example.com, which no IdP can redirect to.\n")
        out.append("        # Must match the VirtualService host exactly, scheme included.\n")
        out.append("        url: https://%s\n" % host)
        done = True
open(path, "w").writelines(out)
sys.exit(0 if done else 1)
PY1
    echo "   url:             https://$HOST  (inserted under configs.cm)"
  fi

  # verify by PARSING, not by grepping what we just wrote
  python3 - "$HR" "$HOST" <<'PY2'
import sys, yaml
path, host = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(path))
got = d["spec"]["values"]["configs"]["cm"]["url"]
want = "https://" + host
assert got == want, "configs.cm.url is %r, expected %r" % (got, want)
# Who owns argocd-secret differs per cluster and is NOT a universal invariant.
# op-dev sets createSecret:false because its Argo adopted a 49-day-old raw
# install whose argocd-secret already held server.secretkey and TLS -- Helm
# creating it would regenerate the key and end every session. op-qa was
# greenfield and has no configs.secret block, so Helm owns it there. This
# decides how an OIDC clientSecret gets in: merged by ExternalSecret on dev,
# contended with Helm on qa.
sec = d["spec"]["values"]["configs"].get("secret")
if sec is None:
    owner = "Helm (no configs.secret block)"
elif sec.get("createSecret") is False:
    owner = "pre-existing, preserved (createSecret: false)"
else:
    owner = "Helm (createSecret: %r)" % sec.get("createSecret")
print("   parsed back:     configs.cm.url = %s" % got)
print("   argocd-secret:   %s" % owner)
PY2

  # ---- 2. the VirtualService (op-dev only) --------------------------------
  if [ "$BR" = "op-dev" ]; then
  # ---- derive the external-dns targets from a route that already serves on THIS
    # ---- cluster, and prove that route belongs to this cluster before trusting it.
    GRAF="infrastructure/grafana/virtualservice.yaml"
    [ -f "$GRAF" ] || { echo "!! $GRAF missing on $BR" >&2; exit 1; }
    GHOST=$(grep -oE '[a-z0-9.-]+\.usxpress\.io' "$GRAF" | head -1)
    case "$GHOST" in
      *".$SUFFIX") echo "   reference route: $GHOST (belongs to $BR)" ;;
      *) echo "!! $GRAF on branch $BR claims '$GHOST', which is not .$SUFFIX." >&2
         echo "   That branch's routes are a copy from another cluster. Refusing to" >&2
         echo "   derive anything from them -- fix that first." >&2; exit 1 ;;
    esac
    TARGETS=$(grep -oE 'external-dns\.alpha\.kubernetes\.io/target: *"[^"]+"' "$GRAF" \
              | sed 's/.*"\(.*\)"/\1/')
    [ -n "$TARGETS" ] || { echo "!! no external-dns target on $GRAF" >&2; exit 1; }
    echo "$TARGETS" | tr ',' '\n' | grep -qvE '^10\.10\.82\.[0-9]+$' \
      && { echo "!! target list has a non-10.10.82.x entry: $TARGETS" >&2; exit 1; } || true
    echo "   targets:         $TARGETS"

    VS="infrastructure/argocd/virtualservice-argocd.yaml"
    if [ -f "$VS" ]; then
      echo "   VirtualService already exists, leaving alone"
    else
      cat > "$VS" <<VSEOF
---
# INFRA-1639 — the Argo CD UI on op-usxpress-dev.
#
# Same shape as infrastructure/grafana/virtualservice.yaml on this branch, which
# is known to serve. Copied from a working route on THIS cluster rather than from
# another branch — op-prod's copy of this file claims op-dev hostnames, which is
# what that mistake looks like.
#
# Routes to port 80 deliberately. The HelmRelease sets \`server.insecure: true\`,
# so argocd-server speaks plain HTTP and expects TLS to terminate at the gateway.
# Routing to 443 would be TLS inside TLS and fail looking like a cert problem.
#
# No new certificate is needed: istio-ingress/shared-http already terminates
# *.$SUFFIX with wildcard-op-dev-tls (verified on-cluster 2026-08-24).
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: argocd
  namespace: argocd
  annotations:
    # REQUIRED here. external-dns runs with --source=istio-virtualservice and
    # normally takes the record target from the ingress gateway's LoadBalancer
    # address, but istio-ingressgateway on this cluster is ClusterIP with
    # hostNetwork, so there is no address to take. Without this annotation
    # external-dns writes no record at all: the VirtualService is created, Flux
    # reports Ready, and the hostname simply never resolves.
    #
    # These are the seven worker InternalIPs (talos-wk-op-dev-1..7), which is
    # where the ingressgateway DaemonSet runs. Taken from the grafana route on
    # this same branch so every op-dev record agrees.
    external-dns.alpha.kubernetes.io/target: "$TARGETS"
spec:
  gateways:
    - istio-ingress/shared-http
  hosts:
    - $HOST
  http:
    - route:
        - destination:
            host: argocd-server.argocd.svc.cluster.local
            port:
              number: 80
VSEOF
      echo "   VirtualService:  $VS"
    fi

    KUS="infrastructure/argocd/kustomization.yaml"
    [ -f "$KUS" ] || { echo "!! $KUS missing" >&2; exit 1; }
    BEFORE=$(python3 -c 'import sys,yaml;print(len(yaml.safe_load(open(sys.argv[1]))["resources"]))' "$KUS")
    EXPECT=$((BEFORE + 1))
    if grep -q 'virtualservice-argocd.yaml' "$KUS"; then
      echo "   kustomization already lists it"
      EXPECT=$BEFORE
    else
      # Insert after the LAST existing resource entry, not at EOF. Appending
      # put it below a trailing comment block about AppProjects -- still a valid
      # sixth sequence item (comments do not break a YAML block sequence, and the
      # parse check confirmed 6), but it read as though that comment described it.
      python3 - "$KUS" <<'PY0'
import sys
path = sys.argv[1]
lines = open(path).readlines()
last = max(i for i, l in enumerate(lines) if l.startswith("  - ") and ".yaml" in l)
if not lines[last].endswith("\n"):
    lines[last] += "\n"
lines.insert(last + 1, "  - virtualservice-argocd.yaml\n")
open(path, "w").writelines(lines)
PY0
    fi
    AFTER=$(python3 -c 'import sys,yaml;print(len(yaml.safe_load(open(sys.argv[1]))["resources"]))' "$KUS")
    [ "$AFTER" -eq "$EXPECT" ] \
      || { echo "!! kustomization resources went $BEFORE -> $AFTER, expected $EXPECT" >&2; exit 1; }
    grep -q 'virtualservice-argocd.yaml' "$KUS" \
      || { echo "!! virtualservice-argocd.yaml is not in $KUS" >&2; exit 1; }
    echo "   kustomization:   $BEFORE -> $AFTER resources"

    python3 - "$VS" "$HOST" "$TARGETS" <<'PY3'
import sys, yaml
path, host, targets = sys.argv[1], sys.argv[2], sys.argv[3]
d = yaml.safe_load(open(path))
assert d["kind"] == "VirtualService", d["kind"]
assert d["spec"]["hosts"] == [host], d["spec"]["hosts"]
assert d["spec"]["gateways"] == ["istio-ingress/shared-http"], d["spec"]["gateways"]
r = d["spec"]["http"][0]["route"][0]["destination"]
assert r["port"]["number"] == 80, "must be 80: server.insecure means TLS ends at the gateway"
ann = d["metadata"]["annotations"]["external-dns.alpha.kubernetes.io/target"]
assert ann == targets, (ann, targets)
print("   parsed back:     %s -> %s:80, %d dns targets"
      % (host, r["host"], len(targets.split(","))))
PY3
  fi

  git add -A infrastructure/argocd
  if [ -x scripts/check-foreign-cluster-ids.sh ]; then
    scripts/check-foreign-cluster-ids.sh || { echo "!! foreign cluster id check failed" >&2; exit 1; }
  fi

  echo
  echo "-------- git diff origin/$BR --------"
  git --no-pager diff --cached "origin/$BR"
  echo "-------- end --------"

  # Commit unconditionally. A dry run that leaves the worktree dirty makes the
  # NEXT branch's checkout fail -- which is why op-qa never ran on 2026-08-24.
  # The commit sits on a local topic branch that -B recreates each run; only
  # --push publishes anything.
  if true; then
    git commit -q -m "INFRA-1639: give Argo CD a real URL on $BR

configs.cm.url was never set, so it was the chart default
https://argocd.example.com. Argo builds every link it emits, and its OIDC
redirect_uri, from that value -- so no SSO provider can be configured until it
is correct. Set to https://$HOST." || echo "   nothing to commit"
    if [ "$PUSH" = "yes" ]; then
      git push -q -u origin "$TOPIC" --force-with-lease
      echo "   pushed $TOPIC"
    else
      echo "   committed to local $TOPIC (not pushed)"
    fi
  fi
  git checkout -q "$BR" 2>/dev/null || git checkout -q -
done

echo
[ "$PUSH" = "yes" ] || cat <<'DONE'
Committed to local topic branches; NOTHING PUSHED. Read the diffs above, then
re-run with --push. Each run recreates the topic branches from origin, so a
local commit here is not a decision you are stuck with.
DONE
