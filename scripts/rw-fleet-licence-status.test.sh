#!/usr/bin/env bash
# Both-directions test for rw-fleet-licence-status.sh, driven by replayed kubectl output.
#
# The cases that matter are the ones where the script must NOT say "fine": a pod that is
# Running but has restarted 532 times, a licence that is syntactically valid but expires next
# week, and a cluster nobody could reach. That last one is the reason this file exists — an
# unreachable cluster reporting as healthy is how a fleet claim becomes false.
#
# Run: bash scripts/rw-fleet-licence-status.test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

jwt() { python3 - "$1" <<'PY'
import base64, json, sys, time
b = lambda o: base64.urlsafe_b64encode(json.dumps(o).encode()).decode().rstrip("=")
print(b({"alg":"RS512","typ":"JWT"}) + "." +
      b({"sub":"RW","tier":"all","exp":int(time.time())+int(sys.argv[1])}) + ".sig")
PY
}

pods_json() { # $1 = "name:phase:restarts" triples, space separated
  python3 - "$1" <<'PY'
import datetime, json, sys
items = []
for spec in sys.argv[1].split():
    parts = spec.split(":")
    n, phase, r = parts[0], parts[1], int(parts[2])
    cs = {"restartCount": r}
    if len(parts) > 3:      # minutes the current container instance has been up
        t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=int(parts[3]))
        cs["state"] = {"running": {"startedAt": t.strftime("%Y-%m-%dT%H:%M:%SZ")}}
    items.append({"metadata": {"name": n}, "status": {"phase": phase,
                  "containerStatuses": [cs]}})
print(json.dumps({"items": items}))
PY
}

secret_json() { python3 - "$1" <<'PY'
import base64, json, sys
print(json.dumps({"data": {"RW_LICENSE_KEY": base64.b64encode(sys.argv[1].encode()).decode()}}))
PY
}

# Fake onprem-kubectl: <fake> <cluster> -- <kubectl args...>
cat > "$TMP/fake" <<'FAKE'
#!/usr/bin/env bash
cluster="$1"; shift; shift          # drop cluster and the literal --
args="$*"
base="$FIXTURE/$cluster"
[ -d "$base" ] || exit 1            # cluster not in the fixture = unreachable
ns=""
case "$args" in *"-n risingwave-2 "*) ns=risingwave-2 ;; *"-n risingwave "*) ns=risingwave ;; esac
case "$args" in
  "get ns risingwave-2")   [ -d "$base/risingwave-2" ] && echo ok || exit 1 ;;
  "get ns risingwave")     [ -d "$base/risingwave" ]   && echo ok || exit 1 ;;
  *"get pods -o json"*)    cat "$base/$ns/pods.json" ;;
  *"get externalsecret rw-license-key"*) echo -n "rw-license-key" ;;
  *"get secret rw-license-key -o json"*) [ -f "$base/$ns/secret.json" ] && cat "$base/$ns/secret.json" || exit 1 ;;
  *"get secret rw-license-key"*)         [ -f "$base/$ns/secret.json" ] && echo ok || exit 1 ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$TMP/fake"

mkns() { # $1 = cluster dir, $2 = ns, $3 = pod spec, $4 = licence plaintext ("" = no secret)
  mkdir -p "$1/$2"
  pods_json "$3" > "$1/$2/pods.json"
  [ -n "$4" ] && secret_json "$4" > "$1/$2/secret.json"
  return 0
}

run() { RW_FLEET_KUBECTL="$TMP/fake" FIXTURE="$1" bash scripts/rw-fleet-licence-status.sh ${2:-} > "$TMP/out" 2>&1; echo $?; }

want() { # $1 name, $2 pattern that must appear
  if grep -qE "$2" "$TMP/out"; then printf '  PASS  %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n        wanted /%s/:\n' "$1" "$2"; sed 's/^/          /' "$TMP/out"; fail=$((fail+1)); fi
}
wantnot() { # $1 name, $2 pattern that must NOT appear
  if grep -qE "$2" "$TMP/out"; then printf '  FAIL  %s (saw /%s/)\n' "$1" "$2"; sed 's/^/          /' "$TMP/out"; fail=$((fail+1))
  else printf '  PASS  %s\n' "$1"; pass=$((pass+1)); fi
}

GOOD=$(jwt 3628800)   # 42 days, like the real one
HEALTHY="risingwave-meta-0:Running:0 risingwave-console-1:Running:0"

echo "== rw-fleet-licence-status"

# 1. The whole fleet healthy. If this cannot pass, the script is a constant.
F="$TMP/f1"; mkns "$F/op-dev" risingwave "$HEALTHY" "$GOOD"; mkns "$F/op-dev" risingwave-2 "$HEALTHY" "$GOOD"
mkns "$F/op-qa" risingwave "$HEALTHY" "$GOOD"; mkns "$F/op-prod" risingwave "$HEALTHY" "$GOOD"
rc=$(run "$F"); want "healthy fleet -> every ns OK" 'OK .+risingwave: 2/2 Running, none restarting'
want "healthy fleet -> exit 0 and clean verdict" 'healthy on every cluster checked'
[ "$rc" = 0 ] && { printf '  PASS  %s\n' "healthy fleet -> rc 0"; pass=$((pass+1)); } \
              || { printf '  FAIL  %s (rc=%s)\n' "healthy fleet -> rc 0" "$rc"; fail=$((fail+1)); }

# 2. dev's risingwave-2 must be covered too — it is dev-only and easy to forget.
want "dev risingwave-2 is checked" 'risingwave-2: 2/2 Running'

# 3. Running with 532 restarts is the exact shape prod was in, called healthy by gate 3.
F="$TMP/f2"; mkns "$F/op-prod" risingwave "risingwave-meta-0:Running:0 risingwave-console-1:Running:532" "$GOOD"
run "$F" op-prod >/dev/null; want "crashlooping console -> BAD" 'BAD .+CRASHLOOPING: risingwave-console-1\(532 restarts, last'
wantnot "crashlooping console -> not called healthy" 'healthy on every cluster checked'
# The verdict must name the problem it actually has. A run with 1 bad and 0 unknown used to
# print the UNKNOWN sentence, sending the reader to look for a cluster that was fine.
want "bad-only run -> verdict says live fault, not UNKNOWN" 'NOT clean — 1 live fault'
wantnot "bad-only run -> does not blame an UNKNOWN" 'nobody looked at'

# 4. The placeholder. Synced, present, worthless.
F="$TMP/f3"; mkns "$F/op-qa" risingwave "$HEALTHY" "PLACEHOLDER_INJECT_REAL_LICENSE"
run "$F" op-qa >/dev/null; want "placeholder licence -> BAD" 'BAD .+holds no compact JWT'

# 5. Valid format, expiring next week. Indistinguishable from healthy without the exp claim.
F="$TMP/f4"; mkns "$F/op-prod" risingwave "$HEALTHY" "$(jwt 907200)"
run "$F" op-prod >/dev/null; want "licence expiring in 10d -> BAD" 'BAD .+EXPIRES IN 10 DAYS'

# 6. Already expired — where prod lands on 2026-10-15 if nobody renews.
F="$TMP/f5"; mkns "$F/op-prod" risingwave "$HEALTHY" "$(jwt -86400)"
run "$F" op-prod >/dev/null; want "expired licence -> BAD" 'BAD .+EXPIRED or unparseable'

# 7. THE ONE THAT MATTERS FOR A FLEET CLAIM. op-qa was genuinely unreachable earlier today.
#    An unreachable cluster must be UNKNOWN, must not read as "not deployed", and must not
#    let the run call itself clean.
F="$TMP/f6"; mkns "$F/op-dev" risingwave "$HEALTHY" "$GOOD"; mkns "$F/op-prod" risingwave "$HEALTHY" "$GOOD"
rc=$(run "$F")   # op-qa absent from the fixture entirely
want "unreachable cluster -> UNKNOWN" 'UNKNOWN .+op-qa'
wantnot "unreachable cluster -> never reported as healthy fleet" 'healthy on every cluster checked'
want "unreachable cluster -> says an UNKNOWN is not a pass" 'an UNKNOWN is not a pass'

# 7b. A cumulative restart count never falls. A pod with 532 restarts that has been up for
#     six hours has RECOVERED, and calling it CRASHLOOPING forever is how a check gets
#     ignored. It must still be visible -- WARN, not silence.
F="$TMP/f6b"; mkns "$F/op-prod" risingwave "risingwave-meta-0:Running:0 risingwave-console-1:Running:532:360" "$GOOD"
run "$F" op-prod >/dev/null
want "recovered pod -> WARN, not BAD" 'WARN .+recovered but scarred: risingwave-console-1\(532 restarts, stable 6h\)'
wantnot "recovered pod -> not called an active crashloop" 'CRASHLOOPING'
# A WARN must not be laundered into "healthy" by the summary line, which is the line people read.
wantnot "recovered pod -> verdict does not claim healthy" 'is healthy on every cluster'
want "recovered pod -> verdict points at the WARN lines" 'read the WARN lines'

# 7c. THE MASKING CASE. A pod whose sidecar has been up for 133h while its main container
#     sits in CrashLoopBackOff. Reading only state.running.startedAt made the healthy
#     sibling win the minimum, and op-dev prometheus-server was reported "1565 restarts,
#     stable 133h" while its restart count climbed by 3 between two runs half an hour apart.
F="$TMP/f6c"; mkdir -p "$F/op-prod/risingwave"
python3 - > "$F/op-prod/risingwave/pods.json" <<'MASK'
import datetime, json
now = datetime.datetime.now(datetime.timezone.utc)
old = (now - datetime.timedelta(hours=133)).strftime("%Y-%m-%dT%H:%M:%SZ")
recent = (now - datetime.timedelta(minutes=4)).strftime("%Y-%m-%dT%H:%M:%SZ")
print(json.dumps({"items": [
  {"metadata": {"name": "risingwave-meta-0"},
   "status": {"phase": "Running", "containerStatuses": [
      {"restartCount": 0, "state": {"running": {"startedAt": old}}}]}},
  {"metadata": {"name": "prometheus-server-1"},
   "status": {"phase": "Running", "containerStatuses": [
      {"restartCount": 0,    "state": {"running": {"startedAt": old}}},
      {"restartCount": 1565, "state": {"waiting": {"reason": "CrashLoopBackOff"}},
       "lastState": {"terminated": {"finishedAt": recent}}}]}}]}))
MASK
secret_json "$GOOD" > "$F/op-prod/risingwave/secret.json"
run "$F" op-prod >/dev/null
want "crashlooping container behind a healthy sidecar -> BAD" 'BAD .+prometheus-server-1\(1565 restarts, in CrashLoopBackOff NOW\)'
wantnot "masked crashloop -> not called stable" 'stable 133h'
wantnot "masked crashloop -> verdict is not clean" 'No live faults'

# 8. Tally invariant: every OK/BAD line printed must reach the FLEET summary. This is what
#    catches a counter incremented inside a subshell, which cost rw-prod-status its verdict.
F="$TMP/f7"; mkns "$F/op-dev" risingwave "$HEALTHY" "$GOOD"; mkns "$F/op-qa" risingwave "$HEALTHY" "$GOOD"
mkns "$F/op-prod" risingwave "risingwave-meta-0:Running:0 risingwave-console-1:Running:900" "$GOOD"
run "$F" >/dev/null
po=$(grep -c '^  OK  ' "$TMP/out"); pb=$(grep -c '^  BAD ' "$TMP/out")
fo=$(sed -n 's/^=== FLEET  \([0-9]*\) ok.*/\1/p' "$TMP/out"); fb=$(sed -n 's/^=== FLEET  [0-9]* ok, [0-9]* warn, \([0-9]*\) bad.*/\1/p' "$TMP/out")
if [ "$po" = "$fo" ] && [ "$pb" = "$fb" ]; then
  printf '  PASS  tally matches printed lines (%s ok, %s bad)\n' "$po" "$pb"; pass=$((pass+1))
else
  printf '  FAIL  tally lost lines: printed %s ok/%s bad, FLEET says %s/%s\n' "$po" "$pb" "$fo" "$fb"; fail=$((fail+1))
fi

# 9. THE REAL PATH. Cases 1-8 all set RW_FLEET_KUBECTL and never execute cluster
#    resolution at all -- which is how the first version shipped with
#    `onprem_resolve_ctx | sed`: a pipeline, so the ONPREM_KC it exports died in the
#    subshell and the script hit an unbound variable under `set -u` and stopped dead after
#    one line. Thirteen green tests said nothing about it. HOME is pointed at an empty
#    directory so ~/.kube is empty on any machine, making this deterministic on WSL too.
mkdir -p "$TMP/emptyhome/.kube"
HOME="$TMP/emptyhome" bash scripts/rw-fleet-licence-status.sh > "$TMP/out" 2>&1; rc=$?
want "real path: unreachable -> UNKNOWN, not a crash" 'UNKNOWN   cannot reach op-dev'
want "real path: reaches all three clusters" 'UNKNOWN   cannot reach op-prod'
if [ "$rc" -eq 2 ]; then printf '  PASS  %s\n' "real path: all-unknown exits 2, not 0"; pass=$((pass+1))
else printf '  FAIL  %s (rc=%s, must be 2)\n' "real path: all-unknown exits 2, not 0" "$rc"; fail=$((fail+1)); fi

# 10. Guard the specific defect: the resolver must never be called in a subshell, because
#     the variables it exports are the entire point of calling it.
# Strip comments before matching. The first version of this check flagged the explanatory
# comment in the script that quotes the very pattern it forbids -- the authoring-gate-hooks
# trap where a guard makes documenting the danger impossible.
if sed 's/[[:space:]]*#.*$//' scripts/rw-fleet-licence-status.sh \
   | grep -qE "onprem_resolve_ctx[^)]*\||\\\$\(\s*onprem_resolve_ctx"; then
  printf '  FAIL  %s\n' "onprem_resolve_ctx is called in a subshell — its exports are lost"; fail=$((fail+1))
else
  printf '  PASS  %s\n' "onprem_resolve_ctx is called in this shell"; pass=$((pass+1))
fi

# 11. The embedded python runs inside python3 -c '...' — a single-quoted SHELL string. One
#     apostrophe in a comment ("op-dev's") closes it and the shell starts parsing python.
#     Cost a broken script on 2026-09-03. Same family as prose-through-shell-strings.
# bash -n is the assertion, because that is exactly what an escaped apostrophe breaks: the
# shell stops seeing python and starts parsing it. It would not catch a BALANCED pair of
# apostrophes, which would parse but corrupt the python; that case is uncovered and named.
if bash -n scripts/rw-fleet-licence-status.sh 2>/dev/null; then
  printf '  PASS  %s\n' "script still parses (an apostrophe in a python -c block breaks this)"; pass=$((pass+1))
else
  printf '  FAIL  %s\n' "script does not parse — apostrophe in a single-quoted python -c block?"; fail=$((fail+1))
fi

printf '\n  passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
