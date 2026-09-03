#!/usr/bin/env bash
# Tests for onprem_resolve_ctx's candidate selection, with kubectl stubbed on PATH.
#
# The resolver used to take head -1 of the candidate list. op-qa has two kubeconfigs — an
# SSO context and a break-glass cert one — so an expired 8-hour SSO session reported the
# whole cluster unreachable while a working config sat second. A false UNKNOWN is worse
# than a failure, because it is indistinguishable from "not deployed there".
#
# Trying every candidate is only safe if NOTHING is relaxed while doing it. Cases 3 and 4
# are the ones that matter: a candidate pointing at the wrong endpoint, or reaching a
# cluster whose live node name belongs to a different environment, must still be REFUSED
# rather than accepted because it was the only one that answered.
#
# Run: bash scripts/lib-onprem-ctx.test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

# Stub kubectl. Behaviour per kubeconfig is driven by files in $STUB.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
kcfile=""; ctx=""; args=""
for a in "$@"; do
  case "$a" in
    --kubeconfig=*) kcfile="${a#--kubeconfig=}" ;;
    --context=*)    ctx="${a#--context=}" ;;
    *)              args="$args $a" ;;
  esac
done
name=$(basename "$kcfile")
case "$args" in
  *"config view -o json"*)
      # Which contexts does this file offer, and what server does each point at?
      srv=$(cat "$STUB/$name.server" 2>/dev/null || echo "https://0.0.0.0:6443")
      printf '{"clusters":[{"name":"c","cluster":{"server":"%s"}}],"contexts":[{"name":"%s","context":{"cluster":"c"}}]}' \
        "$srv" "$(cat "$STUB/$name.ctx")" ;;
  *"config view --minify"*)
      cat "$STUB/$name.server" 2>/dev/null || echo "https://0.0.0.0:6443" ;;
  *"get nodes"*)
      [ -f "$STUB/$name.node" ] || exit 1     # no node file = cannot reach
      cat "$STUB/$name.node" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/kubectl"

mkcfg() { # $1 name, $2 ctxname, $3 server, $4 node ("" = unreachable)
  mkdir -p "$HOMEDIR/.kube" "$TMP/stub"
  printf 'apiVersion: v1\nkind: Config\n' > "$HOMEDIR/.kube/$1"
  printf '%s' "$2" > "$TMP/stub/$1.ctx"
  printf '%s' "$3" > "$TMP/stub/$1.server"
  [ -n "$4" ] && printf '%s' "$4" > "$TMP/stub/$1.node"
  return 0
}

try() { # runs the resolver in a fresh shell; echoes "rc|ctx"
  PATH="$TMP/bin:$PATH" HOME="$HOMEDIR" STUB="$TMP/stub" bash -c '
    . scripts/lib-onprem-ctx.sh
    onprem_resolve_ctx "'"$1"'" 2>"'"$TMP"'/err"
    echo "$?|${ONPREM_CTX:-none}"'
}

t() { # $1 name, $2 expected "rc|ctx"
  got=$(try "$3")
  if [ "$got" = "$2" ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n        wanted %s, got %s\n' "$1" "$2" "$got"
       sed 's/^/          /' "$TMP/err"; fail=$((fail+1)); fi
}

echo "== onprem_resolve_ctx candidate selection"

# 1. The op-qa case. First candidate's session is expired; the second works.
HOMEDIR="$TMP/h1"
mkcfg op-usxpress-qa-sso.yaml op-usxpress-qa-sso "https://10.10.82.51:6443" ""
mkcfg op-usxpress-qa.yaml     admin@op-usxpress-qa "https://10.10.82.51:6443" "talos-cp-op-qa-1"
t "expired first candidate -> falls through to the working one" "0|admin@op-usxpress-qa" op-qa

# 2. One good candidate is still the ordinary case.
HOMEDIR="$TMP/h2"
mkcfg op-usxpress-prod.yaml admin@op-usxpress-prod "https://10.10.82.52:6443" "talos-cp-op-prod-1"
t "single good candidate" "0|admin@op-usxpress-prod" op-prod

# 3. SAFETY: a candidate that ANSWERS but is the wrong cluster must be refused, not used
#    just because it was the only one that responded. This is the assertion that must not
#    be relaxed by trying more candidates.
HOMEDIR="$TMP/h3"
mkcfg op-usxpress-qa.yaml admin@op-usxpress-qa "https://10.10.82.51:6443" "talos-cp-op-dev-1"
t "wrong cluster behind the right endpoint -> refused" "2|none" op-qa

# 4. SAFETY: a context whose server is a different endpoint is not a candidate at all.
HOMEDIR="$TMP/h4"
mkcfg op-usxpress-dev.yaml admin@op-usxpress-dev "https://10.10.82.50:6443" "talos-cp-op-dev-1"
t "no context serves this endpoint -> refused" "2|none" op-qa

# 5. Every candidate unreachable -> refuse, and say so per candidate rather than once.
HOMEDIR="$TMP/h5"
mkcfg op-usxpress-qa-sso.yaml op-usxpress-qa-sso "https://10.10.82.51:6443" ""
mkcfg op-usxpress-qa.yaml     admin@op-usxpress-qa "https://10.10.82.51:6443" ""
t "all candidates unreachable -> refused" "2|none" op-qa
if grep -q "op-usxpress-qa-sso" "$TMP/err" && grep -q "op-usxpress-qa.yaml" "$TMP/err"; then
  printf '  PASS  %s\n' "names every candidate it tried"; pass=$((pass+1))
else
  printf '  FAIL  %s\n' "names every candidate it tried"; sed 's/^/          /' "$TMP/err"; fail=$((fail+1))
fi
if grep -q "aws sso login --profile op-qa" "$TMP/err"; then
  printf '  PASS  %s\n' "tells you how to fix an op-qa session"; pass=$((pass+1))
else
  printf '  FAIL  %s\n' "tells you how to fix an op-qa session"; fail=$((fail+1))
fi

printf '\n  passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
