#!/usr/bin/env bash
# Read everything a DX/Octopus-deployed app's CLOUD deployment can tell us, so the
# on-prem onboarding starts from measurement instead of from a questionnaire.
#
# Answers, for one app, from the running cluster:
#   - which ECR registry/repository/digest the image actually comes from
#   - CPU, memory, replicas, probes        (DX generates these; no repo holds them)
#   - every env var NAME, and where each one comes from: literal, ConfigMap, or Secret
#   - which ConfigMaps and Secrets it mounts, and their KEY NAMES
#   - which AWS Secrets Manager secrets exist for it, and their KEY NAMES
#   - whether it carries OTEL endpoints, and whether it uses Entra auth
#
# READ-ONLY. No create, no patch, no delete, no exec, no port-forward, no test pod.
# Secret VALUES are never printed: key names go through jq, values never reach stdout.
# ConfigMap values are printed only with --values, because a ConfigMap is where a
# leaked credential usually hides.
#
# Usage, on WSL:
#   bash scripts/discover-cloud-app.sh --context <ctx> --find pricing
#   bash scripts/discover-cloud-app.sh --context <ctx> -n <ns> --app <workload>
#   ... --values            also print ConfigMap values
#   ... --aws-profile <p>   also enumerate AWS Secrets Manager key names
#
# Every failure prints NOT MEASURED and names WHICH fault. An empty result is never
# reported as absence.
set -uo pipefail

CTX=""; NS=""; APP=""; FIND=""; AWSP=""; SHOW_VALUES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --context)     CTX="${2:-}"; shift 2 ;;
    -n|--namespace) NS="${2:-}"; shift 2 ;;
    --app)         APP="${2:-}"; shift 2 ;;
    --find)        FIND="${2:-}"; shift 2 ;;
    --aws-profile) AWSP="${2:-}"; shift 2 ;;
    --values)      SHOW_VALUES=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say(){ printf '%s\n' "$*"; }
hdr(){ printf '\n== %s\n' "$*"; }
nm(){  printf 'NOT MEASURED  %s\n' "$*"; }

for t in kubectl jq; do
  command -v "$t" >/dev/null 2>&1 || { nm "$t absent on this box -- nothing read"; exit 2; }
done

# An empty --context silently selects the CURRENT context. On 2026-10-09 that sent four
# on-prem queries to a cloud cluster and the output read as a finding about on-prem.
if [ -z "$CTX" ]; then
  nm "--context is required. Refusing to inherit the current context."
  say ""
  say "contexts on this box:"
  kubectl config get-contexts -o name 2>/dev/null | sed 's/^/  /'
  exit 2
fi
if ! kubectl config get-contexts -o name 2>/dev/null | grep -qxF "$CTX"; then
  nm "context '$CTX' is not in this kubeconfig -- a login cannot create it"
  say "contexts on this box:"
  kubectl config get-contexts -o name 2>/dev/null | sed 's/^/  /'
  exit 2
fi

K=(kubectl --context "$CTX" --request-timeout=20s)

hdr "which cluster am I talking to"
SRV=$(kubectl --context "$CTX" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
say "context: $CTX"
say "server:  ${SRV:-<none>}"
# An open port is not an authenticated session. Until this succeeds every finding below
# is NOT MEASURED, including the reassuring ones.
if ! VER=$("${K[@]}" get --raw /version 2>&1); then
  nm "cannot authenticate to $CTX. This says nothing about the app."
  say "  $(printf '%s' "$VER" | head -2)"
  exit 2
fi
say "version: $(printf '%s' "$VER" | jq -r '.gitVersion // "?"' 2>/dev/null)"

# ── finder mode ─────────────────────────────────────────────────────────────
if [ -n "$FIND" ]; then
  hdr "workloads whose name contains '$FIND'"
  OUT=$("${K[@]}" get deploy,statefulset,cronjob,job -A \
          -o jsonpath='{range .items[*]}{.kind}{"\t"}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' \
          2>/dev/null | grep -i -- "$FIND")
  if [ -z "$OUT" ]; then
    nm "no workload name contains '$FIND'."
    say "  An empty match is a bad filter at least as often as an absent app."
    say "  Try a shorter substring, or list the namespaces:"
    say "    kubectl --context $CTX get ns"
  else
    printf '%s\n' "$OUT" | sed 's/^/  /'
    say ""
    say "re-run with the namespace and name, e.g.:"
    printf '%s\n' "$OUT" | head -1 | awk -v c="$CTX" \
      '{print "  bash scripts/discover-cloud-app.sh --context "c" -n "$2" --app "$3}'
  fi
  [ -z "$APP" ] && exit 0
fi

if [ -z "$APP" ] || [ -z "$NS" ]; then
  nm "need -n <namespace> and --app <workload>. Run --find <substring> first."
  exit 2
fi

# Resolve the workload without guessing its kind.
KIND=""
for k in deployment statefulset cronjob; do
  if "${K[@]}" -n "$NS" get "$k" "$APP" >/dev/null 2>&1; then KIND="$k"; break; fi
done
if [ -z "$KIND" ]; then
  nm "no deployment, statefulset or cronjob named '$APP' in namespace '$NS' on $CTX"
  say "  workloads in that namespace:"
  "${K[@]}" -n "$NS" get deploy,statefulset,cronjob -o name 2>/dev/null | sed 's/^/    /'
  exit 2
fi
say "resolved: $KIND/$APP in namespace $NS"

J=$("${K[@]}" -n "$NS" get "$KIND" "$APP" -o json 2>/dev/null)
if [ -z "$J" ]; then nm "could not read $KIND/$APP as json"; exit 2; fi
# A CronJob's pod template sits one level deeper than a Deployment's.
POD=$(printf '%s' "$J" | jq '.spec.jobTemplate.spec.template.spec // .spec.template.spec')

hdr "the image -- which registry, which repository, which digest"
printf '%s' "$POD" | jq -r '.containers[] | "  container: \(.name)\n  image:     \(.image)"'
printf '%s' "$J" | jq -r '
  [.status.containerStatuses // [], (.spec.template.spec.containers // [])] | flatten
  | map(select(.imageID? // null)) | .[] | "  imageID:   \(.imageID)"' 2>/dev/null
# The registry account is the first field of the image reference; that is the answer to
# "which ECR account does this app actually push to", and it must not be assumed.
printf '%s' "$POD" | jq -r '.containers[].image' | while IFS= read -r IMG; do
  case "$IMG" in
    *.dkr.ecr.*.amazonaws.com/*)
      ACCT=${IMG%%.dkr.ecr.*}; REST=${IMG#*.amazonaws.com/}
      REG=${IMG#*.dkr.ecr.}; REG=${REG%%.amazonaws.com/*}
      say "  -> ECR account $ACCT, region $REG, repository ${REST%%[:@]*}" ;;
    *) say "  -> NOT an ECR reference: $IMG" ;;
  esac
done
say ""
say "  pods actually running this image:"
"${K[@]}" -n "$NS" get pods -o json 2>/dev/null | jq -r --arg a "$APP" '
  .items[] | select(.metadata.name | startswith($a))
  | "    \(.metadata.name)  \(.status.phase)  restarts=\(
      [.status.containerStatuses[]?.restartCount] | add // 0)  started=\(
      .status.startTime // "?")"' | head -20

hdr "sizing -- DX generated this, and no repo holds it"
printf '%s' "$J" | jq -r '"  replicas (spec):   \(.spec.replicas // "n/a")"'
printf '%s' "$J" | jq -r '"  replicas (ready):  \(.status.readyReplicas // "n/a")"'
printf '%s' "$J" | jq -r '"  strategy:          \(.spec.strategy.type // .spec.schedule // "n/a")"'
printf '%s' "$POD" | jq -r '.containers[] |
  "  [\(.name)] requests: \(.resources.requests // {} | tojson)",
  "  [\(.name)] limits:   \(.resources.limits   // {} | tojson)",
  "  [\(.name)] liveness: \(if .livenessProbe  then (.livenessProbe|tojson)  else "none" end)",
  "  [\(.name)] readines: \(if .readinessProbe then (.readinessProbe|tojson) else "none" end)"'
printf '%s' "$POD" | jq -r '"  serviceAccount:    \(.serviceAccountName // "default")"'
printf '%s' "$POD" | jq -r '"  nodeSelector:      \(.nodeSelector // {} | tojson)"'

hdr "environment variables -- NAME and SOURCE, never a value"
# This is the inventory the whole onboarding turns on. Three sources, and the third
# (secretKeyRef) is the one DX creates and the app team cannot see.
printf '%s' "$POD" | jq -r '
  .containers[] as $c | $c.env // [] | .[] |
  if   .valueFrom.secretKeyRef    then "  SECRET     \(.name)  <- secret/\(.valueFrom.secretKeyRef.name):\(.valueFrom.secretKeyRef.key)"
  elif .valueFrom.configMapKeyRef then "  CONFIGMAP  \(.name)  <- cm/\(.valueFrom.configMapKeyRef.name):\(.valueFrom.configMapKeyRef.key)"
  elif .valueFrom.fieldRef        then "  FIELDREF   \(.name)  <- \(.valueFrom.fieldRef.fieldPath)"
  elif .valueFrom.resourceFieldRef then "  RESOURCE   \(.name)"
  else "  LITERAL    \(.name)  (\((.value // "") | length) chars, in the manifest)"
  end' | sort
say ""
say "  envFrom (whole ConfigMaps/Secrets injected at once):"
printf '%s' "$POD" | jq -r '.containers[].envFrom // [] | .[] |
  "    \(if .secretRef then "secret/" + .secretRef.name else "cm/" + .configMapRef.name end)"' \
  | sort -u | sed 's/^/  /'
N=$(printf '%s' "$POD" | jq '[.containers[].env // [] | .[]] | length')
say ""
say "  total env vars declared: ${N:-0}"
if [ "${N:-0}" = "0" ]; then
  say "  ^ zero is suspicious, not clean: check envFrom above and any mounted volume."
fi

hdr "mounted ConfigMaps and Secrets"
printf '%s' "$POD" | jq -r '.volumes // [] | .[] |
  if   .secret    then "  secret/\(.secret.secretName)   -> mounted as a volume"
  elif .configMap then "  cm/\(.configMap.name)          -> mounted as a volume"
  else empty end'

hdr "ConfigMap contents -- key names, and values only with --values"
for CM in $(printf '%s' "$POD" | jq -r '
    [ (.containers[].env // [] | .[] | .valueFrom.configMapKeyRef.name // empty),
      (.containers[].envFrom // [] | .[] | .configMapRef.name // empty),
      (.volumes // [] | .[] | .configMap.name // empty) ] | unique | .[]'); do
  D=$("${K[@]}" -n "$NS" get cm "$CM" -o json 2>/dev/null)
  if [ -z "$D" ]; then nm "cm/$CM not readable (RBAC, or it does not exist)"; continue; fi
  say "  cm/$CM"
  if [ "$SHOW_VALUES" = "1" ]; then
    printf '%s' "$D" | jq -r '.data // {} | to_entries[] | "    \(.key) = \(.value)"' | cut -c1-160
  else
    printf '%s' "$D" | jq -r '.data // {} | to_entries[] | "    \(.key)  (\(.value|length) chars)"'
  fi
done

hdr "Secret KEY NAMES -- values are never read into stdout"
for S in $(printf '%s' "$POD" | jq -r '
    [ (.containers[].env // [] | .[] | .valueFrom.secretKeyRef.name // empty),
      (.containers[].envFrom // [] | .[] | .secretRef.name // empty),
      (.volumes // [] | .[] | .secret.secretName // empty) ] | unique | .[]'); do
  D=$("${K[@]}" -n "$NS" get secret "$S" -o json 2>/dev/null)
  if [ -z "$D" ]; then nm "secret/$S not readable (RBAC, or it does not exist)"; continue; fi
  say "  secret/$S  type=$(printf '%s' "$D" | jq -r '.type')  keys=$(printf '%s' "$D" | jq '.data|length')"
  # An EMPTY key is the failure mode ESO produces: green sync, unusable value, pod dies
  # at container creation with RESTARTS 0. Count the bytes, never print them.
  printf '%s' "$D" | jq -r '.data // {} | to_entries[] |
    "    \(.key)  (\(.value|length) b64 chars)\(if (.value|length) == 0 then "   <-- EMPTY" else "" end)"'
  say "  annotations (an ESO-managed secret says so here):"
  printf '%s' "$D" | jq -r '.metadata.annotations // {} | keys[]' 2>/dev/null | sed 's/^/    /'
done

hdr "DX and Octopus fingerprints on this workload"
# What DX stamped on it tells you it generated the manifest, and what Octopus release
# produced the running copy.
printf '%s' "$J" | jq -r '.metadata.labels // {} | to_entries[] | "  label  \(.key)=\(.value)"'
printf '%s' "$J" | jq -r '.metadata.annotations // {} | to_entries[]
  | select(.key | test("octopus|dx|deploy|release|kubectl.kubernetes.io/last-applied"; "i") | not)
  | "  annot  \(.key)=\(.value)"' | cut -c1-160
say "  (last-applied-configuration suppressed: it repeats the whole manifest)"
say ""
say "  managedFields -- WHO last wrote this object:"
printf '%s' "$J" | jq -r '.metadata.managedFields // [] | .[] |
  "    \(.manager)  op=\(.operation)  at=\(.time // "?")"'

hdr "Entra / auth coupling -- does a DX app registration matter here?"
# Every DX deploy destroys and recreates the app registration, so a consumer holding a
# snapshotted client id breaks on someone else's release. If these are present, the
# migration has an identity hazard nobody has raised.
AUTHV=$(printf '%s' "$POD" | jq -r '[.containers[].env // [] | .[] | .name]
  | map(select(test("AUTH__|CLIENT_ID|CLIENTID|TENANT|AZURE|ENTRA"; "i"))) | .[]')
if [ -z "$AUTHV" ]; then
  say "  no env var name matches AUTH__/CLIENT_ID/TENANT/AZURE/ENTRA"
  say "  ^ that is evidence about env vars only. A config file or a mounted secret"
  say "    could still carry it; grep the app's own config to be sure."
else
  printf '%s\n' "$AUTHV" | sed 's/^/  /'
  say "  -> treat the per-deploy app-registration recreation as a migration hazard."
fi

hdr "OTEL / telemetry -- the variables that must survive the move"
OT=$(printf '%s' "$POD" | jq -r '[.containers[].env // [] | .[] | .name]
  | map(select(test("OTEL|OTLP|TELEMETRY|TRACE|JAEGER"; "i"))) | .[]')
if [ -z "$OT" ]; then
  say "  NONE found as env vars."
  say "  ^ If this app's logs DO reach the Application Monitoring dashboard, they are"
  say "    arriving some other way -- a sidecar, a node agent, or an envFrom above."
  say "    Find out which BEFORE on-prem, or logging dies green there."
else
  printf '%s\n' "$OT" | sed 's/^/  /'
  say "  -> every one of these needs a home in values-<env>.yaml on-prem."
fi

hdr "AWS Secrets Manager -- what DX created for this app"
if [ -z "$AWSP" ]; then
  nm "no --aws-profile given; the DX-created half of the inventory was not read"
elif ! command -v aws >/dev/null 2>&1; then
  nm "aws CLI absent on this box"
elif ! aws configure list-profiles 2>/dev/null | grep -qxF "$AWSP"; then
  nm "profile '$AWSP' is NOT CONFIGURED on this box -- a login cannot fix that"
elif ! ACC=$(aws sts get-caller-identity --profile "$AWSP" --query Account --output text 2>/dev/null); then
  nm "profile '$AWSP' has no valid session -- run: aws sso login --profile $AWSP"
else
  say "  account: $ACC  (profile $AWSP)"
  LIST=$(aws secretsmanager list-secrets --profile "$AWSP" --max-items 400 \
           --query 'SecretList[].Name' --output text 2>/dev/null | tr '\t' '\n' | grep -i -- "$APP")
  if [ -z "$LIST" ]; then
    nm "no secret name contains '$APP' in account $ACC"
    say "    An empty match is a bad filter as often as an absent secret. Try a shorter"
    say "    substring: aws secretsmanager list-secrets --profile $AWSP --query 'SecretList[].Name'"
  else
    printf '%s\n' "$LIST" | while IFS= read -r SEC; do
      [ -n "$SEC" ] || continue
      say "  $SEC"
      # The value transits to jq and is never printed. Key names are what we need.
      if ! aws secretsmanager get-secret-value --profile "$AWSP" --secret-id "$SEC" \
             --query SecretString --output text 2>/dev/null \
             | jq -r 'if type=="object" then (keys[] | "      " + .) else "      (not a JSON object)" end' 2>/dev/null; then
        say "      NOT MEASURED -- could not read or parse this secret"
      fi
    done
  fi
fi

hdr "what this did NOT measure"
say "  - Octopus project variables      -> scripts/octopus-dump-app-vars.py --project <name>"
say "  - what the app reads from its own config files, unseen by Kubernetes"
say "  - whether a value is CORRECT. Presence is not validity."
say "  - the DX Terraform that created any of the above (ask Parul or Rohit)"
say ""
say "Read-only run complete. Nothing was created, patched or deleted."
