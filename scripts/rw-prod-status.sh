#!/usr/bin/env bash
# INFRA-1674 — is RisingWave actually DONE on op-usxpress-prod?
#
# READ-ONLY. get/describe only, no kubectl run/debug/exec-for-testing (rule 3), every
# call pinned to op-prod through onprem-kubectl.sh, which resolves the cluster BY ENDPOINT.
#
# The AWS layer applied cleanly on 2026-09-01 and it is tempting to call that done. It is
# one of seven gates. This walks all seven and prints DONE / NOT DONE / UNKNOWN per gate.
#
# UNKNOWN is a real answer here. A check that cannot reach the cluster must say so rather
# than report "absent" — twelve false absences on 2026-08-25 came from exactly that.
#
#   bash scripts/rw-prod-status.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable ONLY so rw-prod-status.test.sh can replay recorded output. Unset in
# normal use, so behaviour against a real cluster is unchanged.
K="${RW_STATUS_KUBECTL:-$SCRIPT_DIR/onprem-kubectl.sh}"
NS=risingwave          # QA and prod are always `risingwave`; risingwave-2 is dev-only.
CLUSTER=op-usxpress-prod
ACCT=937464026810
# Pin the region on every regional call. Secrets Manager answers
# ResourceNotFoundException for a secret that exists in ANOTHER region, which
# is indistinguishable from "absent" unless you pinned the region. Omitting it
# reported all six prod secrets missing on 2026-09-01 while
# wire-prod-risingwave.py -- which passes --region -- confirmed all six ok
# seconds later on the same machine, same profile. CLAUDE.md rule 2.
REGION=us-east-2

pass=0; fail=0; unknown=0
gate() { printf '\n== %s\n' "$*"; }
ok()   { printf '   DONE      %s\n' "$*"; pass=$((pass+1)); }
no()   { printf '   NOT DONE  %s\n' "$*"; fail=$((fail+1)); }
huh()  { printf '   UNKNOWN   %s\n' "$*"; unknown=$((unknown+1)); }

# ── reachability first: everything below is meaningless without it ────────────
if ! out=$("$K" op-prod -- get --raw='/readyz' 2>&1); then
  echo "!! cannot reach op-prod: $out" >&2
  echo "!! ABORTING. Nothing below would be a finding about prod — only about the" >&2
  echo "!! connection. Rebuild the kubeconfig if needed:" >&2
  echo "!!   bash $SCRIPT_DIR/onprem-prod-kubeconfig.sh" >&2
  exit 3
fi
echo "op-prod reachable (/readyz=$out)"

gate "1. AWS layer — IRSA role, bucket, six secrets (applied 2026-09-01)"
if command -v aws >/dev/null 2>&1 && aws sts get-caller-identity --profile ops-controller >/dev/null 2>&1; then
  who=$(aws sts get-caller-identity --profile ops-controller --query Account --output text)
  if [ "$who" != "$ACCT" ]; then
    huh "ops-controller lands in $who, not $ACCT — not checking AWS through the wrong account"
  else
    role=$(aws iam get-role --role-name "${CLUSTER}-risingwave" --profile ops-controller \
             --query 'Role.Arn' --output text 2>/dev/null) \
      && ok "IRSA role $role" || no "IAM role ${CLUSTER}-risingwave absent"
    aws s3api head-bucket --bucket "risingwave-state-${CLUSTER}" \
      --profile ops-controller --region "$REGION" >/dev/null 2>&1 \
      && ok "bucket risingwave-state-${CLUSTER}" || no "bucket risingwave-state-${CLUSTER} absent"
    # describe-secret by exact name, one per secret. `list-secrets --filters
    # Key=name,Values=op-usxpress-prod/risingwave/` returns ZERO here: the filter
    # tokenises its value and does not prefix-match a slashed path, so it reported
    # all five absent on 2026-09-01 minutes after the apply log printed their ARNs.
    # wire-prod-risingwave.py already used describe-secret; this now matches it.
    for sname in root postgres svc-reporting secret_store_private_key console_license_key dex_entra_client_secret; do
      out=$(aws secretsmanager describe-secret --secret-id "${CLUSTER}/risingwave/${sname}" \
              --profile ops-controller --region "$REGION" --query 'Name' --output text 2>&1)
      if [ $? -eq 0 ] && [ -n "$out" ] && [ "$out" != "None" ]; then
        ok "secret $out"
      elif printf '%s' "$out" | grep -q "ResourceNotFoundException"; then
        no "secret ${CLUSTER}/risingwave/${sname} absent in $REGION"
      else
        huh "secret ${CLUSTER}/risingwave/${sname}: ${out}"
      fi
    done
  fi
else
  huh "no usable ops-controller AWS session — re-run after 'aws sso login --profile ops-controller'"
fi

gate "2. Flux wiring — the three Kustomizations exist on the cluster"
for k in risingwave-operator risingwave-onprem risingwave-routes; do
  if st=$("$K" op-prod -- -n flux-system get kustomization "$k" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) && [ -n "$st" ]; then
    [ "$st" = "True" ] && ok "Kustomization $k Ready" || no "Kustomization $k Ready=$st"
  else
    no "Kustomization $k not present — wire-prod-risingwave.py has not landed"
  fi
done

gate "3. Namespace + workloads actually running"
if "$K" op-prod -- get ns "$NS" >/dev/null 2>&1; then
  ok "namespace $NS exists"
  # Shared with rw-fleet-licence-status.sh. These had two implementations and on
  # 2026-09-03 they disagreed about op-prod risingwave-console in front of the operator --
  # one said "stable 3h", this one said "crashlooping" -- because only one of them knew
  # that a cumulative restart count cannot tell crashing-now from settled-hours-ago.
  v=$("$K" op-prod -- -n "$NS" get pods -o json 2>/dev/null \
       | RESTART_LIMIT=10 python3 "$SCRIPT_DIR/lib-pod-health.py")
  tot=$(printf '%s' "$v" | python3 -c 'import json,sys;print(json.load(sys.stdin)["total"])')
  nr=$(printf  '%s' "$v" | python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin)["notready"]))')
  ch=$(printf  '%s' "$v" | python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin)["churn"]))')
  hl=$(printf  '%s' "$v" | python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin)["healed"]))')
  if   [ "$tot" -lt 0 ];  then huh "could not read pods in $NS as JSON — not an empty namespace"
  elif [ "$tot" -eq 0 ];  then no "namespace $NS has no pods"
  elif [ -n "$nr" ];      then no "pods not Running: $nr"
  elif [ -n "$ch" ];      then no "$tot/$tot pods Running, but crashlooping: $ch"
  elif [ -n "$hl" ];      then ok "$tot/$tot pods Running; recovered but scarred: $hl"
  else                         ok "$tot/$tot pods Running, none restarting"
  fi
else
  no "namespace $NS does not exist"
fi

gate "4. ServiceAccount carries the prod IRSA role"
want="arn:aws:iam::${ACCT}:role/${CLUSTER}-risingwave"
if got=$("$K" op-prod -- -n "$NS" get sa risingwave \
           -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null); then
  [ "$got" = "$want" ] && ok "sa/risingwave -> $got" \
                       || no "sa/risingwave -> ${got:-<no annotation>}, want $want"
else
  no "ServiceAccount risingwave not found in $NS"
fi

gate "5. ExternalSecrets — synced AND holding real content"
# SecretSynced proves the sync ran, not that the value works. Check the licence itself.
if es=$("$K" op-prod -- -n "$NS" get externalsecrets --no-headers 2>/dev/null) && [ -n "$es" ]; then
  # Read the CONDITION, not a column position. Until 2026-09-03 this counted rows where
  # $NF != "SecretSynced" -- but `get externalsecrets` prints NAME STORE REFRESH STATUS
  # READY, so $NF is READY ("True") and never equals "SecretSynced". Every row matched.
  # The gate could not return a pass, and on 2026-09-03 it reported "7 not SecretSynced"
  # against a namespace where all seven were synced.
  tot=$("$K" op-prod -- -n "$NS" get externalsecrets \
         -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c .)
  syn=$("$K" op-prod -- -n "$NS" get externalsecrets \
         -o jsonpath='{range .items[*]}{.status.conditions[0].reason}{"\n"}{end}' 2>/dev/null \
         | grep -c '^SecretSynced$')
  if [ "$tot" -gt 0 ] && [ "$syn" -eq "$tot" ]; then
    ok "all $tot ExternalSecrets SecretSynced"
  else
    no "$((tot - syn)) of $tot ExternalSecret(s) not SecretSynced"
  fi

  # The licence. Discover the Secret rather than hardcoding a name -- the old check looked
  # for "risingwave-console-license" and reported UNKNOWN because the object is
  # "rw-license-key". A name guessed wrong reads exactly like a thing that is not there.
  lsec=$("$K" op-prod -- -n "$NS" get externalsecret rw-license-key \
          -o jsonpath='{.spec.target.name}' 2>/dev/null)
  [ -n "$lsec" ] || lsec=rw-license-key
  lic=$("$K" op-prod -- -n "$NS" get secret "$lsec" -o json 2>/dev/null \
        | python3 -c 'import base64,json,sys
try: d=json.load(sys.stdin).get("data",{})
except Exception: sys.exit(0)
for v in d.values():
    try: t=base64.b64decode(v).decode()
    except Exception: continue
    if t.count(".")==2 and t.startswith("eyJ"): print(t); break' 2>/dev/null)
  if [ -z "$lic" ]; then
    huh "no compact JWT in secret $lsec -- a SecretSynced ExternalSecret is not evidence of content"
  else
    # A JWT is only good until its exp. This licence is short-dated: renewal is the work.
    exp=$(printf '%s' "$lic" | python3 -c 'import base64,json,sys
t=sys.stdin.read().split(".")[1]
t+="="*(-len(t)%4)
print(json.loads(base64.urlsafe_b64decode(t)).get("exp",0))' 2>/dev/null)
    now=$(date +%s)
    if [ -n "$exp" ] && [ "$exp" -gt "$now" ] 2>/dev/null; then
      days=$(( (exp - now) / 86400 ))
      if [ "$days" -lt 30 ]; then
        no "console licence is a real JWT but EXPIRES IN $days DAYS ($(date -u -d "@$exp" +%Y-%m-%d)) -- renew it"
      else
        ok "console licence is a real JWT, expires $(date -u -d "@$exp" +%Y-%m-%d) ($days days)"
      fi
    else
      no "console licence JWT is expired or has no readable exp -- the console will refuse to start"
    fi
  fi
else
  no "no ExternalSecrets in $NS"
fi

gate "6. Ingress — Gateways, VirtualServices, and DNS that resolves"
# Search ALL namespaces and report where it lives. Pinning istio-ingress reported
# both Gateways absent on 2026-09-01 against a cluster we had confirmed carries
# tcp-passthrough — an empty result from the wrong selector, not an absence.
for g in shared-http tcp-passthrough; do
  hit=$("$K" op-prod -- get gateway.networking.istio.io -A --no-headers 2>/dev/null | awk -v g="$g" '$2==g {print $1}')
  [ -n "$hit" ] && ok "Gateway $g in namespace $hit" || no "Gateway $g absent in every namespace"
done
vs=$("$K" op-prod -- -n "$NS" get virtualservice -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.hosts[*]}{"\n"}{end}' 2>/dev/null)
if [ -z "$vs" ]; then
  no "no VirtualService in $NS"
else
  # Process substitution, NOT `echo "$vs" | while`. A piped while runs in a SUBSHELL, so
  # every ok/no inside it printed its line and incremented a counter that died with the
  # subshell. On 2026-09-03 the body printed 14 DONE lines and RESULT said 12 -- the two
  # missing ones were exactly these. The dangerous half is `no`: a VirtualService publishing
  # a foreign host would print NOT DONE without raising `fail`, and the script would then
  # announce "COMPLETE" with a NOT DONE line above it. A fail-open in the verdict itself.
  while read -r name hosts; do
    [ -z "$name" ] && continue
    case "$hosts" in
      *op-dev*|*op-qa*) no "VirtualService $name publishes a FOREIGN host: $hosts" ;;
      *)                ok "VirtualService $name -> $hosts" ;;
    esac
  done < <(printf '%s\n' "$vs")
  for h in $(echo "$vs" | awk '{print $2}'); do
    case "$h" in *op-prod*) getent hosts "$h" >/dev/null 2>&1 \
        && ok "DNS resolves $h" || no "DNS does not resolve $h — external-dns has not published it" ;;
    esac
  done
fi

gate "7. Backup — a real Velero backup, not just the Schedule"
if "$K" op-prod -- -n velero get schedule risingwave-metastore >/dev/null 2>&1; then
  ok "Schedule risingwave-metastore exists"
  last=$("$K" op-prod -- -n velero get backups --no-headers 2>/dev/null \
          | grep risingwave | awk '$2=="Completed"' | tail -1)
  [ -n "$last" ] && ok "completed backup: $last" \
                 || no "no COMPLETED risingwave backup yet — the Schedule has not produced one"
else
  no "Velero Schedule risingwave-metastore absent"
fi

printf '\n== RESULT  %d done, %d not done, %d unknown\n' "$pass" "$fail" "$unknown"
[ "$fail" -eq 0 ] && [ "$unknown" -eq 0 ] \
  && echo "RisingWave on $CLUSTER is COMPLETE." \
  || echo "RisingWave on $CLUSTER is NOT complete — see NOT DONE / UNKNOWN above."
