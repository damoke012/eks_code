#!/usr/bin/env bash
# INFRA-1674 -- register op-usxpress-prod's Dex callback on the shared RisingWave
# registration, so the prod console can complete an Entra login.
#
# dev, QA and prod all use ONE app registration (e112d6ce...). A new environment is a
# redirect-URI addition, not a new identity request -- the client ID and secret are the
# same everywhere and only the URI differs.
#
# `az ad app update --web-redirect-uris` REPLACES the list wholesale. Adding prod's URI
# naively would silently drop dev's and QA's and break two working logins to fix a third.
# So: read, merge, assert nothing was dropped, write, read back.
#
#   scripts/entra-rw-dex-redirect.sh            # show what is registered
#   scripts/entra-rw-dex-redirect.sh --add
set -euo pipefail
APP_ID="${APP_ID:-e112d6ce-cc60-4884-9898-8fcc5b78b0b1}"
TENANT="${TENANT:-bbb5a66d-5c9f-482a-969a-a40304b6bc8d}"
WANT=("https://risingwave-dashboard.op-prod.usxpress.io/dex/callback")

command -v az >/dev/null 2>&1 || { echo "!! az is not on PATH. Run this on WSL." >&2; exit 2; }
TID=$(az account show --query tenantId --output tsv 2>/dev/null || true)
[ "$TID" = "$TENANT" ] || { echo "!! signed in to tenant '${TID:-<none>}', expected $TENANT" >&2
                            echo "   az login --tenant $TENANT" >&2; exit 2; }

show() {
  echo "--- web redirect URIs on $APP_ID (Dex redeems these server-side) ---"
  az ad app show --id "$APP_ID" --query 'web.redirectUris' --output json
}

MODE="${1:---show}"
case "$MODE" in
  --show) show ;;
  --add)
    CUR=$(az ad app show --id "$APP_ID" --query 'web.redirectUris' --output json)
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
# This field is replaced wholesale -- dev and QA must survive the write.
assert all(u in out for u in cur), "an existing URI would have been dropped"
print(" ".join(out))
PY
)
    # shellcheck disable=SC2086
    az ad app update --id "$APP_ID" --web-redirect-uris $MERGED
    echo
    show
    cat <<'NEXT'

The URI is registered. The prod console still will not start until console_license_key
holds a real licence -- SSO and the licence are independent blockers, and fixing this one
does not make the console reachable on its own.
NEXT
    ;;
  *) echo "usage: $0 [--show|--add]" >&2; exit 2 ;;
esac
