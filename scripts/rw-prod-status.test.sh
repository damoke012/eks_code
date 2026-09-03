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
# The four cases below are the ones that matter: a healthy namespace MUST come back DONE
# (the direction the old code could never produce), and each unhealthy shape must come back
# NOT DONE for its own reason. Case 4 exists because a valid licence is only valid until a
# date, and "expires next week" reads identical to "fine" if you only check the format.
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
  *) exit 1 ;;
esac
FAKE
chmod +x "$TMP/fake-kubectl"

mkfixture() { # $1 = dir, $2 = reasons (newline sep), $3 = licence plaintext
  mkdir -p "$1"
  printf 'dex-entra-client-secret\npg-credentials\nrisingwave-pg-credentials\nrw-license-key\nrw-root-credentials\nrw-secret-store-private-key\nrw-service-account-credentials\n' > "$1/es-names"
  printf '%s\n' "$2" > "$1/es-reasons"
  printf 'rw-license-key' > "$1/es-target"
  secret_json "$3" > "$1/secret.json"
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

printf '\n  passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
