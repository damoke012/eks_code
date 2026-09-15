#!/usr/bin/env bash
# Replay recorded kubectl output through flux-kustomization-health.sh, BOTH directions.
#
# Why this exists: the first version of that script had a SyntaxError in its parser and
# printed "all 4 Kustomizations Ready" from a crash. A detector that cannot go red is not
# a detector, it is a constant. See wip/rw-console-org-sync/
# 2026-09-15-recreate-strategy-stuck-reconcile.md
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"; touch "$T/fake.yaml"
fails=0

cat > "$T/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$FAKE_MODE" in
  sick)  cat "$FAKE_DIR/sick.json" ;;
  well)  cat "$FAKE_DIR/well.json" ;;
  auth)  echo "error: You must be logged in to the server (Unauthorized)" >&2; exit 1 ;;
  down)  echo "dial tcp 10.10.82.51:6443: connect: connection refused" >&2; exit 1 ;;
  empty) echo '{"items":[]}' ;;
  junk)  printf '{"items": [' ;;
esac
EOF
chmod +x "$T/bin/kubectl"

python3 - "$T" <<'PY'
import json, sys, pathlib
d = pathlib.Path(sys.argv[1])
def k(name, ready, reason="", msg="", suspend=False):
    return {"metadata": {"namespace": "flux-system", "name": name},
            "spec": {"suspend": suspend},
            "status": {"conditions": [{"type": "Ready", "status": ready,
                                       "reason": reason, "message": msg}]}}
# The exact message op-usxpress-qa emitted for ~4 hours on 2026-09-15.
dry = ('Deployment/risingwave/risingwave-console dry-run failed (Invalid): Deployment.apps '
       '"risingwave-console" is invalid: spec.strategy.rollingUpdate: Forbidden: may not be '
       "specified when strategy `type` is 'Recreate'")
(d / "sick.json").write_text(json.dumps({"items": [
    k("risingwave-onprem", "False", "ReconciliationFailed", dry),
    k("risingwave-operator", "True", "ReconciliationSucceeded"),
    k("istio-base", "True", "ReconciliationSucceeded"),
    k("velero", "True", "ReconciliationSucceeded", suspend=True)]}))
(d / "well.json").write_text(json.dumps({"items": [
    k("risingwave-onprem", "True", "ReconciliationSucceeded"),
    k("istio-base", "True", "ReconciliationSucceeded")]}))
PY

check() { # name mode want_exit want_grep
  local out rc
  out=$(PATH="$T/bin:$PATH" FAKE_DIR="$T" FAKE_MODE="$2" \
        bash "$HERE/flux-kustomization-health.sh" --kubeconfig "$T/fake.yaml" 2>&1)
  rc=$?
  if [ "$rc" -ne "$3" ]; then
    echo "FAIL $1: exit $rc, want $3"; printf '%s\n' "$out" | sed 's/^/     /'
    fails=$((fails+1)); return
  fi
  if ! printf '%s' "$out" | grep -q "$4"; then
    echo "FAIL $1: output missing /$4/"; printf '%s\n' "$out" | sed 's/^/     /'
    fails=$((fails+1)); return
  fi
  echo "ok   $1"
}

check "goes RED on the stuck dry-run"        sick  3 'NOT-READY'
check "names the forbidden field"            sick  3 'rollingUpdate: Forbidden'
check "goes GREEN when all Ready"            well  0 'all 2 Kustomizations Ready'
check "flags a suspended Kustomization"      sick  3 'SUSPENDED'
check "auth failure is NOT a verdict"        auth  7 'CANNOT AUTHENTICATE'
check "unreachable is NOT a verdict"         down  7 'CANNOT REACH'
check "zero rows is NOT health"              empty 7 'NO Kustomizations returned'
check "a dead parser is NOT health"          junk  7 'CANNOT PARSE'

[ "$fails" -eq 0 ] && echo "flux-kustomization-health.test: all pass" || \
  echo "flux-kustomization-health.test: $fails failure(s)"
exit $((fails > 0))
