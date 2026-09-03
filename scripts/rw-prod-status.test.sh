#!/usr/bin/env bash
# Self-test for rw-prod-status.sh gate 5, driven by replayed kubectl output.
#
# Why this exists. On 2026-09-03 gate 5 reported "7 ExternalSecret(s) not SecretSynced"
# against a namespace where all seven were synced. It counted rows where $NF != "SecretSynced",
# but `get externalsecrets` prints NAME STORE REFRESH STATUS READY, so $NF is READY ("True")
# and never equals "SecretSynced". Every row always matched. **The gate had no passing
# branch** — it was not a check, it was a constant — and it had been shipping that way.
#
# No amount of reading it caught that. Running it against known input does, in one second.
#
# Ten cases. A healthy namespace MUST come back DONE (the direction the old code could never
# produce), and each unhealthy shape must come back NOT DONE for its own reason. Two are
# worth calling out: a licence expiring next week reads identical to a healthy one if you
# only check the format, and case 8 asserts the RESULT tally equals the lines actually
# printed -- which is what catches a counter incremented inside a subshell, anywhere.
#
# Run: bash scripts/rw-prod-status.test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

jwt() { # $1 = seconds from now until exp
  python3 - "$1" <<'PY'
import base64, json, sys, time
b = lambda o: base64.urlsafe_b64encode(json.dumps(o).encode()).decode().rstrip("=")
print(b({"alg":"RS512","typ":"JWT"}) + "." +
      b({"sub":"RW_test","tier":"all","exp":int(time.time())+int(sys.argv[1])}) + ".sig")
PY
}

secret_json() { # $1 = plaintext value to place under RW_LICENSE_KEY
  python3 - "$1" <<'PY'
import base64, json, sys
print(json.dumps({"data": {"RW_LICENSE_KEY": base64.b64encode(sys.argv[1].encode()).decode()}}))
PY
}

# A stand-in for onprem-kubectl.sh. Called as: <fake> op-prod -- <kubectl args...>
# Answers only what gate 5 asks; every other gate gets an empty result and reports its own
# NOT DONE/UNKNOWN, which this test does not assert on.
cat > "$TMP/fake-kubectl" <<'FAKE'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *--raw=/readyz*)                                   echo ok ;;
  *"get externalsecrets"*--no-headers*)              cat "$FIXTURE/es-names" ;;
  *"get externalsecrets"*metadata.name*)             cat "$FIXTURE/es-names" ;;
  *"get externalsecrets"*conditions*)                cat "$FIXTURE/es-reasons" ;;
  *"get externalsecret rw-license-key"*)             cat "$FIXTURE/es-target" ;;
  *"get secret"*)                                    cat "$FIXTURE/secret.json" ;;
  *"get kustomization"*)                             echo True ;;
  *"get ns risingwave"*)                             echo "namespace/risingwave" ;;
  *"get pods -o json"*)                              cat "$FIXTURE/pods.json" ;;
  *"get sa risingwave"*)                             cat "$FIXTURE/sa-arn" ;;
  *"get gateway"*)                                   cat "$FIXTURE/gateways" ;;
  *"get virtualservice"*)                            cat "$FIXTURE/vs" ;;
  *"get schedule"*)                                  echo "schedule/risingwave-metastore" ;;
  *"get backups"*)                                   cat "$FIXTURE/backups" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$TMP/fake-kubectl"

podsjson() { # "name:phase:restarts" triples
  python3 - "$1" <<'PJ'
import json, sys
items = []
for spec in sys.argv[1].split():
    n, phase, r = spec.split(":")
    items.append({"metadata": {"name": n},
                  "status": {"phase": phase, "containerStatuses": [{"restartCount": int(r)}]}})
print(json.dumps({"items": items}))
PJ
}

mkfixture() { # $1 = dir, $2 = reasons (newline sep), $3 = licence plaintext
  mkdir -p "$1"
  printf 'dex-entra-client-secret\npg-credentials\nrisingwave-pg-credentials\nrw-license-key\nrw-root-credentials\nrw-secret-store-private-key\nrw-service-account-credentials\n' > "$1/es-names"
  printf '%s\n' "$2" > "$1/es-reasons"
  printf 'rw-license-key' > "$1/es-target"
  secret_json "$3" > "$1/secret.json"
  # Defaults for the other gates; individual cases overwrite the one they exercise.
  podsjson "risingwave-meta-default-0:Running:0 risingwave-frontend-default-1:Running:0" > "$1/pods.json"
  printf 'arn:aws:iam::937464026810:role/op-usxpress-prod-risingwave' > "$1/sa-arn"
  printf 'istio-ingress  shared-http      45h\nistio-ingress  tcp-passthrough  45h\n' > "$1/gateways"
  printf 'risingwave-dashboard risingwave-dashboard.op-prod.usxpress.io\n' > "$1/vs"
  printf 'risingwave-metastore-20260903 Completed 0 0 45h\n' > "$1/backups"
}

SYNCED=$'SecretSynced\nSecretSynced\nSecretSynced\nSecretSynced\nSecretSynced\nSecretSynced\nSecretSynced'
BROKEN=$'SecretSynced\nSecretSyncedError\nSecretSynced\nSecretSynced\nSecretSyncedError\nSecretSynced\nSecretSynced'

check() { # $1 = name, $2 = fixture dir, $3 = grep -E pattern that MUST appear in gate 5
  FIXTURE="$2" RW_STATUS_KUBECTL="$TMP/fake-kubectl" \
    bash scripts/rw-prod-status.sh 2>/dev/null \
    | sed -n '/== 5\./,/== 6\./p' > "$TMP/out" || true
  if grep -qE "$3" "$TMP/out"; then
    printf '  PASS  %s\n' "$1"; pass=$((pass+1))
  else
    printf '  FAIL  %s\n        wanted /%s/, gate 5 said:\n' "$1" "$3"
    sed 's/^/          /' "$TMP/out"; fail=$((fail+1))
  fi
}

echo "== rw-prod-status gate 5"

# 1. The direction the old code could NEVER produce. This is the whole point of the suite.
mkfixture "$TMP/f1" "$SYNCED" "$(jwt 3628800)"
check "healthy namespace -> DONE" "$TMP/f1" 'DONE +all 7 ExternalSecrets SecretSynced'
check "valid licence -> DONE with expiry" "$TMP/f1" 'DONE +console licence is a real JWT, expires'

# 2. Genuinely unsynced secrets must be counted correctly, not just "all of them".
mkfixture "$TMP/f2" "$BROKEN" "$(jwt 3628800)"
check "2 of 7 unsynced -> NOT DONE, counted" "$TMP/f2" 'NOT DONE +2 of 7 ExternalSecret'

# 3. The placeholder that started all this. Synced, but the content is worthless.
mkfixture "$TMP/f3" "$SYNCED" "PLACEHOLDER_INJECT_REAL_LICENSE"
check "placeholder licence -> not a JWT" "$TMP/f3" 'UNKNOWN +no compact JWT'

# 4. A real JWT that expires next week reads identical to a healthy one on format alone.
# 10.5 days, not exactly 10: the gate floors (exp-now)/86400, so a fixture built at exactly
# 10 days reports 9 as soon as a second elapses. Asserting the exact number still catches a
# units error; pinning it to a boundary only catches the clock.
mkfixture "$TMP/f4" "$SYNCED" "$(jwt 907200)"
check "licence expiring in 10d -> NOT DONE" "$TMP/f4" 'NOT DONE +.*EXPIRES IN 10 DAYS'

# 5. An expired licence is the state prod lands in if nobody renews.
mkfixture "$TMP/f5" "$SYNCED" "$(jwt -86400)"
check "expired licence -> NOT DONE" "$TMP/f5" 'NOT DONE +console licence JWT is expired'

echo
echo "== rw-prod-status other gates"

# 6. A pod that is Running between backoffs is not healthy. This exact shape -- STATUS
#    Running, 532 restarts -- was reported as "12/12 pods Running" on 2026-09-03.
mkfixture "$TMP/f6" "$SYNCED" "$(jwt 3628800)"
podsjson "risingwave-meta-default-0:Running:0 risingwave-console-5b6:Running:532" > "$TMP/f6/pods.json"
gate3() { FIXTURE="$1" RW_STATUS_KUBECTL="$TMP/fake-kubectl" bash scripts/rw-prod-status.sh 2>/dev/null \
            | sed -n '/== 3\./,/== 4\./p' > "$TMP/out"; }
gate3 "$TMP/f6"
if grep -qE 'NOT DONE +.*crashlooping: risingwave-console' "$TMP/out"; then
  printf '  PASS  %s\n' "crashlooping pod -> NOT DONE"; pass=$((pass+1))
else
  printf '  FAIL  %s\n' "crashlooping pod -> NOT DONE"; sed 's/^/          /' "$TMP/out"; fail=$((fail+1))
fi

# 7. Steady pods must still pass, or the new restart check just broke a working gate.
mkfixture "$TMP/f7" "$SYNCED" "$(jwt 3628800)"
gate3 "$TMP/f7"
if grep -qE 'DONE +2/2 pods Running, none restarting' "$TMP/out"; then
  printf '  PASS  %s\n' "steady pods -> DONE"; pass=$((pass+1))
else
  printf '  FAIL  %s\n' "steady pods -> DONE"; sed 's/^/          /' "$TMP/out"; fail=$((fail+1))
fi

# 8. THE INVARIANT. Every DONE/NOT DONE line printed must be counted in RESULT. This is
#    what catches a counter incremented inside a subshell, anywhere in the script -- gate 6
#    used `echo | while`, so its two VirtualService lines printed and vanished from the
#    tally (14 printed, 12 counted, 2026-09-03). Worse for `no`: a foreign host would print
#    NOT DONE without raising fail, and the script would then announce COMPLETE.
mkfixture "$TMP/f8" "$SYNCED" "$(jwt 3628800)"
printf 'risingwave-dashboard risingwave-dashboard.op-prod.usxpress.io\nrisingwave-overview risingwave-overview.op-prod.usxpress.io\n' > "$TMP/f8/vs"
FIXTURE="$TMP/f8" RW_STATUS_KUBECTL="$TMP/fake-kubectl" bash scripts/rw-prod-status.sh 2>/dev/null > "$TMP/full"
pd=$(grep -c '^   DONE ' "$TMP/full"); pn=$(grep -c '^   NOT DONE ' "$TMP/full")
rd=$(sed -n 's/^== RESULT  \([0-9]*\) done.*/\1/p' "$TMP/full")
rn=$(sed -n 's/^== RESULT  [0-9]* done, \([0-9]*\) not done.*/\1/p' "$TMP/full")
if [ "$pd" = "$rd" ] && [ "$pn" = "$rn" ]; then
  printf '  PASS  tally matches printed lines (%s done, %s not done)\n' "$pd" "$pn"; pass=$((pass+1))
else
  printf '  FAIL  tally lost lines to a subshell: printed %s done/%s not done, RESULT says %s/%s\n' \
    "$pd" "$pn" "$rd" "$rn"; fail=$((fail+1))
fi

# 9. A foreign host must reach the VERDICT, not just the screen.
mkfixture "$TMP/f9" "$SYNCED" "$(jwt 3628800)"
printf 'grafana grafana.op-dev.usxpress.io\n' > "$TMP/f9/vs"
FIXTURE="$TMP/f9" RW_STATUS_KUBECTL="$TMP/fake-kubectl" bash scripts/rw-prod-status.sh 2>/dev/null > "$TMP/full9"
# Assert the not-done COUNT, not the absence of "COMPLETE". With the subshell bug this
# case still passed, because gate 1's UNKNOWN happened to suppress the COMPLETE line -- the
# test looked like it worked while the finding never reached the verdict at all.
n9=$(sed -n 's/^== RESULT  [0-9]* done, \([0-9]*\) not done.*/\1/p' "$TMP/full9")
if grep -qE 'NOT DONE +VirtualService grafana publishes a FOREIGN host' "$TMP/full9" \
   && [ "${n9:-0}" -ge 1 ]; then
  printf '  PASS  %s\n' "foreign host reaches the verdict count"; pass=$((pass+1))
else
  printf '  FAIL  %s\n' "foreign host printed but never reached the verdict count"; fail=$((fail+1))
fi

printf '\n  passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
