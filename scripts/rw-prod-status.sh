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
K="$SCRIPT_DIR/onprem-kubectl.sh"
NS=risingwave          # QA and prod are always `risingwave`; risingwave-2 is dev-only.
CLUSTER=op-usxpress-prod
ACCT=937464026810

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

gate "1. AWS layer — IRSA role, bucket, five secrets (applied 2026-09-01)"
if command -v aws >/dev/null 2>&1 && aws sts get-caller-identity --profile ops-controller >/dev/null 2>&1; then
  who=$(aws sts get-caller-identity --profile ops-controller --query Account --output text)
  if [ "$who" != "$ACCT" ]; then
    huh "ops-controller lands in $who, not $ACCT — not checking AWS through the wrong account"
  else
    role=$(aws iam get-role --role-name "${CLUSTER}-risingwave" --profile ops-controller \
             --query 'Role.Arn' --output text 2>/dev/null) \
      && ok "IRSA role $role" || no "IAM role ${CLUSTER}-risingwave absent"
    aws s3api head-bucket --bucket "risingwave-state-${CLUSTER}" --profile ops-controller >/dev/null 2>&1 \
      && ok "bucket risingwave-state-${CLUSTER}" || no "bucket risingwave-state-${CLUSTER} absent"
    # describe-secret by exact name, one per secret. `list-secrets --filters
    # Key=name,Values=op-usxpress-prod/risingwave/` returns ZERO here: the filter
    # tokenises its value and does not prefix-match a slashed path, so it reported
    # all five absent on 2026-09-01 minutes after the apply log printed their ARNs.
    # wire-prod-risingwave.py already used describe-secret; this now matches it.
    for sname in root postgres svc-reporting secret_store_private_key console_license_key dex_entra_client_secret; do
      out=$(aws secretsmanager describe-secret --secret-id "${CLUSTER}/risingwave/${sname}" \
              --profile ops-controller --query 'Name' --output text 2>&1)
      if [ $? -eq 0 ] && [ -n "$out" ] && [ "$out" != "None" ]; then
        ok "secret $out"
      elif printf '%s' "$out" | grep -q "ResourceNotFoundException"; then
        no "secret ${CLUSTER}/risingwave/${sname} absent"
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
  tot=$("$K" op-prod -- -n "$NS" get pods --no-headers 2>/dev/null | wc -l)
  bad=$("$K" op-prod -- -n "$NS" get pods --no-headers 2>/dev/null \
          | awk '$3!="Running" && $3!="Completed"' | wc -l)
  if [ "$tot" -eq 0 ]; then no "namespace $NS has no pods"
  elif [ "$bad" -eq 0 ]; then ok "$tot/$tot pods Running"
  else no "$bad of $tot pods not Running:"
       "$K" op-prod -- -n "$NS" get pods --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"{print "             "$0}'
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
  nr=$("$K" op-prod -- -n "$NS" get externalsecrets --no-headers 2>/dev/null \
        | awk '$NF!="SecretSynced"' | wc -l)
  [ "$nr" -eq 0 ] && ok "all ExternalSecrets SecretSynced" || no "$nr ExternalSecret(s) not SecretSynced"
  lic=$("$K" op-prod -- -n "$NS" get secret risingwave-console-license \
          -o jsonpath='{.data.license}' 2>/dev/null | base64 -d 2>/dev/null)
  if [ -z "$lic" ]; then
    huh "console licence secret not readable under the name checked — confirm the key name before concluding"
  elif printf '%s' "$lic" | grep -qE '^(PLACEHOLDER|CHANGEME|[A-Za-z0-9+/=]{0,24})$'; then
    no "console licence is still the Terraform-generated placeholder (${#lic} chars) — real one is with Steve/Zach"
  else
    ok "console licence is ${#lic} chars, not the generated placeholder"
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
  echo "$vs" | while read -r name hosts; do
    [ -z "$name" ] && continue
    case "$hosts" in
      *op-dev*|*op-qa*) no "VirtualService $name publishes a FOREIGN host: $hosts" ;;
      *)                ok "VirtualService $name -> $hosts" ;;
    esac
  done
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
