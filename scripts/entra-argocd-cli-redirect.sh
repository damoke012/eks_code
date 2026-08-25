#!/usr/bin/env bash
# INFRA-1639 -- let `argocd login --sso` work, for us and for application teams.
#
# The CLI does not redirect to the cluster hostname. It starts a listener on the
# workstation and asks Entra for:
#
#   redirect_uri=http://localhost:8085/auth/callback   with a code_challenge (PKCE)
#
# Two things follow, and both must be right or the login dies at Entra:
#
#  1. That URI is not one of the three cluster callbacks we registered, so it must be
#     added or Entra answers AADSTS50011.
#  2. It must be added as a PUBLIC CLIENT redirect URI, not a web one. The CLI holds no
#     client secret and redeems the code with PKCE; a web-type URI would be refused the
#     same way the SPA attempt was refused earlier today with AADSTS9002327 -- the same
#     lesson from the other direction. argocd-server still redeems ITS codes server-side
#     against the web URIs, and both client types coexist on one registration.
#
# --public-client-redirect-uris REPLACES the list wholesale, exactly like
# --web-redirect-uris. Read, merge, write.
#
#   scripts/entra-argocd-cli-redirect.sh            # show what is registered
#   scripts/entra-argocd-cli-redirect.sh --add
set -euo pipefail
APP_ID="${APP_ID:-42dc0c33-4c56-47a5-b207-d119272997aa}"
TENANT="${TENANT:-bbb5a66d-5c9f-482a-969a-a40304b6bc8d}"
# 8085 is the argocd CLI default. 8080 covers --sso-port 8080, which people reach for
# when 8085 is busy; registering both now avoids a second Entra round trip later.
WANT=("http://localhost:8085/auth/callback" "http://localhost:8080/auth/callback")
MODE="${1:---show}"

command -v az >/dev/null 2>&1 || { echo "!! az is not on PATH. Run this on WSL." >&2; exit 2; }
TID=$(az account show --query tenantId --output tsv 2>/dev/null || true)
[ "$TID" = "$TENANT" ] || { echo "!! signed in to tenant '${TID:-<none>}', expected $TENANT" >&2
                            echo "   az login --tenant $TENANT" >&2; exit 2; }

show() {
  echo "--- web redirect URIs (argocd-server redeems these server-side) ---"
  az ad app show --id "$APP_ID" --query 'web.redirectUris' --output json
  echo "--- public client redirect URIs (the argocd CLI, PKCE, no secret) ---"
  az ad app show --id "$APP_ID" --query 'publicClient.redirectUris' --output json
}

case "$MODE" in
  --show) show ;;
  --add)
    CUR=$(az ad app show --id "$APP_ID" --query 'publicClient.redirectUris' --output json)
    MERGED=$(WANT="${WANT[*]}" python3 - "$CUR" <<'PY'
import json, os, sys
cur = json.loads(sys.argv[1]) or []
want = os.environ["WANT"].split()
out = list(cur)
for u in want:
    if u in out:
        print("   already registered: %s" % u, file=sys.stderr)
    else:
        out.append(u); print("   adding:             %s" % u, file=sys.stderr)
# Never drop what is already there -- this field is replaced wholesale.
assert all(u in out for u in cur), "an existing URI would have been dropped"
print(" ".join(out))
PY
)
    # shellcheck disable=SC2086
    az ad app update --id "$APP_ID" --public-client-redirect-uris $MERGED
    echo
    show
    cat <<'NEXT'

Now, on a workstation with no browser to launch (WSL has no xdg-open):

  argocd login argocd.op-qa.usxpress.io --sso --grpc-web --sso-launch-browser=false

It prints a URL. Open it in Windows; the callback reaches the listener inside WSL.
NEXT
    ;;
  *) echo "usage: $0 [--show|--add]" >&2; exit 2 ;;
esac
