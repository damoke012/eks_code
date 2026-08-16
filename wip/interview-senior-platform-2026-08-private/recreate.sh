#!/usr/bin/env bash
#
# INTERVIEWER AID — Exercise 01. Do not copy into the candidate repo.
#
# Shows the incident behind Exercise 01 without needing a cluster: walks the
# manifest -> ConfigMap -> browser chain, then recreates the app registration
# underneath it and shows why redeploying cannot help.
#
#   ./recreate.sh <path to ui-spec.yaml>
#
# Run it on the shared screen before handing over Exercise 01. ~30 seconds.
set -uo pipefail

SPEC="${1:?usage: recreate.sh <path to hack/ui-spec.yaml>}"
[ -r "$SPEC" ] || { echo "cannot read $SPEC" >&2; exit 1; }

hdr()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
bad()  { printf '\033[1;31m%s\033[0m\n' "$*"; }

# What the manifest pins by hand. Everything else is told relative to this.
PINNED=$(grep -oE '[0-9a-fA-F-]{36}' "$SPEC" | head -1)
ROTATED="b7d419e6-3c85-4f20-88ad-1e6094c7fa32"

hdr "1. Six months ago — the platform generated this app's identity"
echo "   Terraform output:  module=auth / client_id = \"$PINNED\""
echo "   A developer copied that value into the manifest. At the time, it was correct."

hdr "2. What the manifest pins, by hand"
grep -nE 'CLIENT_ID|TENANT_ID|SCOPES' "$SPEC"

hdr "3. The ConfigMap the platform renders — a verbatim copy, nothing inspects it"
awk '
  /^[[:space:]]*configVars:/ { inblk = 1
    print "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: orders-admin-ui-chart\ndata:"
    next }
  inblk {
    if ($0 ~ /^    [^ ].*:/) { sub(/^    /, "  "); print } else { exit }
  }
' "$SPEC"
echo "   -> served to the browser as runtime configuration"

hdr "4. What the guard says about that manifest"
( cd "$(dirname "$SPEC")/.." && go run . "hack/$(basename "$SPEC")"; echo "   exit=$?" )
echo "   The only cheap moment to catch this. It passed."

hdr "5. Last night — the app registration was recreated"
echo "   platform now generates:   $ROTATED"
echo "   browser is still served:  $PINNED   <-- from the manifest"
bad "   These no longer match. Nothing in the platform compares them."

hdr "6. What every user gets at 07:00"
cat <<EOF
   GET https://login.example.com/<tenant>/oauth2/v2.0/authorize
       client_id=$PINNED

   AADSTS700016: Application with identifier '$PINNED'
   was not found in the directory.
EOF

hdr "7. The team redeploys"
echo "   deploy #2 -> platform regenerates the identity, then rewrites the"
echo "               ConfigMap from the manifest. Manifest wins."
echo "   deploy #3 -> same."
echo "   ConfigMap value after both:  $PINNED   <-- UNCHANGED"
echo
bad "   Every deploy is green. The outage does not move."
echo
printf '   \033[1mNow: make the platform refuse this manifest.\033[0m\n\n'
