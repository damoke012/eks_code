#!/usr/bin/env bash
# INFRA-1639 -- show the claims in the token Argo is actually receiving.
#
# Why a script: argocd-server logs the claims as an ESCAPED JSON string inside a
# quoted field (\"groups\":, not "groups":), so a plain grep for a claim name finds
# nothing whether or not the claim is present -- a check that cannot fail open, it
# fails CLOSED, always reporting absence.
#
# Also prints iat per token, so it is obvious whether a fresh sign-in happened or
# the window only caught an existing session polling with its old token.
#
#   scripts/argocd-token-claims.sh op-dev
#   scripts/argocd-token-claims.sh op-dev 10m
set -uo pipefail
BR="${1:-}"; SINCE="${2:-5m}"
case "$BR" in op-dev|op-qa|op-prod) : ;; *)
  echo "!! usage: $0 <op-dev|op-qa|op-prod> [since]" >&2; exit 2 ;; esac

LIB="$(dirname "${BASH_SOURCE[0]}")/lib-onprem-ctx.sh"
# shellcheck source=/dev/null
source "$LIB"; onprem_resolve_ctx "$BR" || exit 1

kubectl --kubeconfig="$ONPREM_KC" --context="$ONPREM_CTX" -n argocd \
  logs deploy/argocd-server --since="$SINCE" 2>/dev/null \
| python3 -c '
import sys, re, json, datetime

now = datetime.datetime.now(datetime.timezone.utc).timestamp()
print("   now: %s" % datetime.datetime.now(datetime.timezone.utc).strftime("%H:%M:%SZ"))
seen, rows = set(), []
pat = re.compile(r'"'"'grpc\.request\.claims="(.*?)" grpc\.request\.content'"'"')
for line in sys.stdin:
    m = pat.search(line)
    if not m: continue
    raw = m.group(1).replace(chr(92)+chr(34), chr(34))
    try: c = json.loads(raw)
    except Exception: continue
    key = (c.get("iat"), c.get("uti"))
    if key in seen: continue
    seen.add(key); rows.append(c)

if not rows:
    print("   no token-bearing calls in this window.")
    print("   Either nobody is signed in, or the window is too short -- try a longer one.")
    raise SystemExit(0)

for c in rows:
    iat = c.get("iat")
    when = datetime.datetime.fromtimestamp(iat, datetime.timezone.utc).strftime("%H:%M:%SZ") if iat else "?"
    age  = int(now - iat) if iat else None
    g = c.get("groups")
    stale = "" if age is None or age < 180 else "   <-- STALE: issued %dm%02ds ago, before any change you just made" % (age // 60, age % 60)
    print("-- token issued %s (%ss ago)  sub %s%s" % (
        when, age if age is not None else "?", str(c.get("preferred_username") or c.get("sub"))[:40], stale))
    print("   claims present: %s" % ", ".join(sorted(c.keys())))
    if g is None:
        if "_claim_names" in c:
            print("   GROUPS: OVERAGE -- Entra sent _claim_names instead of the list;")
            print("           the user is in too many groups for an inline claim.")
        else:
            print("   GROUPS: ABSENT")
    else:
        print("   GROUPS: %d -> %s" % (len(g), ", ".join(g)))
'
