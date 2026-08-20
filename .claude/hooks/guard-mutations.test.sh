#!/usr/bin/env bash
# Self-test for guard-mutations.sh. Both directions: it must block, and it must let through.
HOOK="$(dirname "$0")/guard-mutations.sh"
pass=0; fail=0
PROT="usxpress-prod"      # matches PROTECTED
ACCT="937464026810"       # matches PROTECTED
SAFE="usxpress-dev"       # must NOT match

check() { # check <expected-exit> <label> <command>
  local want=$1 label=$2 cmd=$3 got
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$cmd")" | bash "$HOOK" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf '  ok   %-48s (exit %s)\n' "$label" "$got"
  else fail=$((fail+1)); printf '  FAIL %-48s (want %s, got %s)\n' "$label" "$want" "$got"; fi
}

if grep -q "^PROTECTED=''" "$HOOK"; then
  echo "  guard is UNCONFIGURED — asserting it blocks nothing"
  check 0 'inert: mutating command passes' "kubectl --context=$PROT apply -f x.yaml"
else
  echo "== must BLOCK"
  check 2 'kubectl apply on prod cluster'   "kubectl --context=$PROT apply -f x.yaml"
  check 2 'terraform apply w/ prod account' "terraform apply -var acct=$ACCT"
  check 2 'aws delete- on prod account'     "aws ec2 delete-vpc --vpc-id v --profile $ACCT"
  echo "== must ALLOW"
  check 0 'kubectl get on prod'             "kubectl --context=$PROT get pods -A"
  check 0 'apply on dev'                    "kubectl --context=$SAFE apply -f x.yaml"
  check 0 'terraform plan on prod'          "terraform plan -var acct=$ACCT"
  # Regression: a runbook that merely QUOTES a protected command must not self-block.
  check 0 'heredoc quoting a prod command'  "$(printf 'cat > n.md <<%sEOF%s\nnever run kubectl --context=%s apply\nEOF' "'" "'" "$PROT")"
fi

# --- fail-open regression (added 2026-08-20) --------------------------------------
# The parser is piped with 2>/dev/null. Before this, any payload it could not read
# produced an empty $cmd and was ALLOWED without ever being inspected. A malformed
# payload carrying a real prod mutation bypassed the guard entirely.
echo "== must FAIL CLOSED on unreadable payloads"
raw() { # raw <expected-exit> <label> <payload>
  local want=$1 label=$2 got
  printf '%s' "$3" | bash "$HOOK" >/dev/null 2>&1; got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf '  ok   %-48s (exit %s)\n' "$label" "$got"
  else fail=$((fail+1)); printf '  FAIL %-48s (want %s, got %s)\n' "$label" "$want" "$got"; fi
}
raw 0 'garbage, no mutation'          "not json"
raw 2 'TRUNCATED json, prod mutation' "{\"tool_input\":{\"command\":\"terraform apply -var acct=$ACCT\"}"
raw 2 'mutation under unexpected key' "{\"tool_input\":{\"cmd\":\"terraform destroy -var acct=$ACCT\"}}"
raw 2 'control: well-formed'          "{\"tool_input\":{\"command\":\"terraform apply -var acct=$ACCT\"}}"

echo; echo "passed $pass, failed $fail"; [ "$fail" = 0 ]
