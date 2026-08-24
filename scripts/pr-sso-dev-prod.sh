#!/usr/bin/env bash
# INFRA-1638 -- AWS SSO cluster access on op-usxpress-dev and op-usxpress-prod.
#
# QA has had this since 2026-07-28 and is FULLY GitOps: the manifests live in
# iaac-talos-flux-platform (infrastructure/rbac + infrastructure/aws-iam-authenticator)
# and the Flux Kustomization objects that deliver them live in a SECOND repo,
# iaac-talos-flux-cluster, at clusters/<cluster>/flux-system/infra.yaml.
#
# Dev and prod have NEITHER directory and NO Kustomization. This builds both, on
# both, in both repos.
#
# WHAT IS PER-CLUSTER, AND WHY IT CANNOT BE COPIED
#
#   The permission set usx-on-prem-admins is provisioned to all three accounts,
#   but AWS generates a DIFFERENT suffix per account. Read back 2026-08-24:
#     dev  700736442855  AWSReservedSSO_usx-on-prem-admins_b7447c115978d407
#     qa   527101283767  AWSReservedSSO_usx-on-prem-admins_8c7f139e431625e0
#     prod 937464026810  AWSReservedSSO_usx-on-prem-admins_837df2a43495aaf1
#   A copied ARN does not error. The caller authenticates as system:anonymous and
#   every request returns `forbidden`, which reads exactly like an RBAC bug.
#
#   The cluster ID is baked into the authenticator's server cert by the init
#   container AND passed to the server as --cluster-id. Both must be the same
#   value or every token is rejected as a replay.
#
# NOT IN THIS SCRIPT, DELIBERATELY: the kube-apiserver
# --authentication-token-webhook-config-file flag. That is Talos machine config in
# iaac-talos, it promotes dev -> QA -> prod through OCTOPUS ONLY (CLAUDE.md rule 1),
# and it must land AFTER the authenticator is running -- the reverse order stops
# the apiserver from starting.
#
# BUILT FROM THE BRANCHES (CLAUDE.md rule 7). Refuses to overwrite. Prints every
# diff in full. Pushes nothing without --push.
#
#   scripts/pr-sso-dev-prod.sh --only op-dev
#   scripts/pr-sso-dev-prod.sh --only op-dev --push
set -uo pipefail

PUSH=no; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --push) PUSH=yes; shift ;;
    --only) ONLY="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

PLAT="${PLAT:-$HOME/pr-work/iaac-talos-flux-platform}"
CLUS="${CLUS:-$HOME/pr-work/iaac-talos-flux-cluster}"
TARGETS="${ONLY:-op-dev op-prod}"
TOPIC="infra-1638-sso"
SRC_BRANCH="origin/op-qa"

command -v gh >/dev/null || { echo "!! gh CLI not on PATH" >&2; exit 2; }
[ -d "$PLAT/.git" ] || { echo "!! no checkout at $PLAT" >&2; exit 2; }
[ -d "$CLUS/.git" ] || { echo "!! no checkout at $CLUS" >&2; exit 2; }

# cluster-branch -> account, role suffix, cluster id, cluster-repo directory
meta() {
  case "$1" in
    op-dev)  echo "700736442855 b7447c115978d407 op-usxpress-dev bm-dev" ;;
    op-prod) echo "937464026810 837df2a43495aaf1 op-usxpress-prod op-usxpress-prod" ;;
    *) echo "" ;;
  esac
}

git -C "$PLAT" fetch -q origin || { echo "!! fetch failed in $PLAT" >&2; exit 2; }
git -C "$CLUS" fetch -q origin || { echo "!! fetch failed in $CLUS" >&2; exit 2; }
echo "platform: $PLAT"
echo "cluster:  $CLUS"
echo "push:     $PUSH"

FAILED=0
for B in $TARGETS; do
  read -r ACCT SUFFIX CID CDIR <<<"$(meta "$B")"
  if [ -z "${ACCT:-}" ]; then
    echo "!! unknown target $B"; FAILED=1; continue
  fi

  echo
  echo "==================== $B  (account $ACCT, cluster-id $CID) ===================="

  # ---------------------------------------------------------------- repo 1 --
  git -C "$PLAT" rev-parse --verify -q "origin/$B" >/dev/null \
    || { echo "!! no origin/$B"; FAILED=1; continue; }
  git -C "$PLAT" checkout -q -B "$TOPIC-$B" "origin/$B" \
    || { echo "!! checkout failed"; FAILED=1; continue; }

  if [ -e "$PLAT/infrastructure/rbac" ] || [ -e "$PLAT/infrastructure/aws-iam-authenticator" ]; then
    echo "!! $B already has rbac/ or aws-iam-authenticator/ -- refusing to overwrite. SKIPPING."
    FAILED=1; continue
  fi

  mkdir -p "$PLAT/infrastructure/rbac" "$PLAT/infrastructure/aws-iam-authenticator"

  # rbac/ is cluster-agnostic -- verified 2026-08-24, the only QA strings are two
  # comments. Copy verbatim from the working cluster, then fix those comments.
  for f in kustomization clusterrole-onprem-platform-reader \
           clusterrole-onprem-platform-operator clusterrolebindings-groups; do
    git -C "$PLAT" show "$SRC_BRANCH:infrastructure/rbac/$f.yaml" \
      > "$PLAT/infrastructure/rbac/$f.yaml" || { echo "!! could not read rbac/$f.yaml"; FAILED=1; }
  done
  sed -i "s|# CRDs present on op-usxpress-qa|# CRDs present on $CID|" \
    "$PLAT/infrastructure/rbac/clusterrole-onprem-platform-reader.yaml"
  sed -i "s|# QA-specific vs. the dev runbook's list|# Cluster-specific CRDs; harmless if a group is absent (RBAC is allow-only)|" \
    "$PLAT/infrastructure/rbac/clusterrole-onprem-platform-reader.yaml"

  # authenticator: daemonset/rbac-server/kustomization copy; aws-auth is AUTHORED.
  for f in kustomization rbac-server daemonset; do
    git -C "$PLAT" show "$SRC_BRANCH:infrastructure/aws-iam-authenticator/$f.yaml" \
      > "$PLAT/infrastructure/aws-iam-authenticator/$f.yaml" \
      || { echo "!! could not read aws-iam-authenticator/$f.yaml"; FAILED=1; }
  done

  DS="$PLAT/infrastructure/aws-iam-authenticator/daemonset.yaml"
  N=$(grep -c 'op-usxpress-qa' "$DS")
  if [ "$N" -ne 2 ]; then
    echo "!! daemonset.yaml has $N occurrences of op-usxpress-qa, expected exactly 2"
    echo "   (init -i and --cluster-id). The file has a shape this script does not handle."
    git -C "$PLAT" checkout -q -- . ; git -C "$PLAT" clean -qfd ; FAILED=1; continue
  fi
  sed -i "s|op-usxpress-qa|$CID|g" "$DS"

  # aws-auth: written, not substituted. Five account-id occurrences and a role
  # name in QA's copy is too many chained replacements to trust.
  cat > "$PLAT/infrastructure/aws-iam-authenticator/aws-auth-configmap.yaml" <<EOF
---
# kube-system/aws-auth — the SAME ConfigMap, in the SAME format, as EKS.
# Read by aws-iam-authenticator's \`EKSConfigMap\` backend. If you have read prod's
# aws-auth, you have read this file.
#
# ⚠️ THE ARN MUST HAVE ITS PATH STRIPPED.
# \`aws iam list-roles\` returns the SSO role with a path:
#   arn:aws:iam::$ACCT:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_usx-on-prem-admins_$SUFFIX
# The authenticator canonicalises assumed-role ARNs WITHOUT the path, so write:
#   arn:aws:iam::$ACCT:role/AWSReservedSSO_usx-on-prem-admins_$SUFFIX
# Getting this wrong does not error — the caller authenticates as system:anonymous and
# every request comes back \`forbidden\`, which reads exactly like an RBAC bug.
#
# ⚠️ THE SUFFIX IS PER-ACCOUNT. AWS generates it when the permission set is
# provisioned, so it differs per cluster even though the permission set is the same:
#   dev  700736442855  ..._b7447c115978d407
#   qa   527101283767  ..._8c7f139e431625e0
#   prod 937464026810  ..._837df2a43495aaf1
# Read back from \`aws iam list-roles\` on 2026-08-24. Never copy one from another
# cluster's file.
#
# ⚠️ NEVER hand-edit this on a cluster where it is the only path in. It is the
# highest-blast-radius object in the cluster; a malformed edit locks everyone out.
# Here the x509 admin kubeconfig is an independent way back in — keep it open.
#
# \`groups\` are the SAME groups already bound in ../rbac/. This ConfigMap grants nothing
# by itself; the ClusterRoleBindings do.
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    # Platform Admin — cluster-admin via the onprem-platform-admins binding.
    # SessionNameRaw keeps the email verbatim in audit logs (SessionName would render
    # idris.fagbemi@usxpress.com as idris.fagbemi-usxpress.com). Needs authenticator >= v0.5.0.
    # The sso: prefix keeps these usernames from colliding with cert CNs.
    - rolearn: arn:aws:iam::$ACCT:role/AWSReservedSSO_usx-on-prem-admins_$SUFFIX
      username: "sso:{{SessionNameRaw}}"
      groups:
        - onprem-platform-admins

    # Uncomment as the tiers are needed. These permission sets do not exist yet in
    # any account — check with \`aws iam list-roles --profile <acct>\` before filling
    # a suffix in, and never guess one.
    # - rolearn: arn:aws:iam::$ACCT:role/AWSReservedSSO_usx-on-prem-operators_FILL_FROM_LIST_ROLES
    #   username: "sso:{{SessionNameRaw}}"
    #   groups:
    #     - onprem-platform-operators
    #
    # - rolearn: arn:aws:iam::$ACCT:role/AWSReservedSSO_usx-on-prem-readers_FILL_FROM_LIST_ROLES
    #   username: "sso:{{SessionNameRaw}}"
    #   groups:
    #     - onprem-platform-users
EOF

  # ---- guards: nothing from QA may survive in either directory ----
  # Guard on CODE, not comments. aws-auth deliberately documents all three
  # accounts and suffixes so the next person can see they differ -- a guard that
  # searched whole files would match its own reference table and refuse every
  # time. Two scripts did exactly that earlier today.
  BAD=0
  for pat in '527101283767' 'op-usxpress-qa' 'op-qa-platform' '8c7f139e431625e0'; do
    HITS=$(grep -rn "$pat" "$PLAT/infrastructure/rbac" "$PLAT/infrastructure/aws-iam-authenticator" \
           | grep -vE '^[^:]+:[0-9]+: *#' || true)
    if [ -n "$HITS" ]; then
      echo "!! a QA identifier survived in CODE on $B:"
      printf '%s\n' "$HITS" | sed 's/^/     /'
      BAD=1
    fi
  done
  NC=$(grep -c "$CID" "$DS")
  [ "$NC" -eq 2 ] || { echo "!! cluster id appears $NC times in daemonset.yaml, expected 2"; BAD=1; }
  grep -q "arn:aws:iam::$ACCT:role/AWSReservedSSO_usx-on-prem-admins_$SUFFIX" \
    "$PLAT/infrastructure/aws-iam-authenticator/aws-auth-configmap.yaml" \
    || { echo "!! the mapRoles ARN is not the one read back from account $ACCT"; BAD=1; }
  if [ "$BAD" -ne 0 ]; then
    echo "   SKIPPING $B -- nothing pushed."
    git -C "$PLAT" checkout -q -- . ; git -C "$PLAT" clean -qfd ; FAILED=1; continue
  fi

  for d in rbac aws-iam-authenticator; do
    if command -v kubectl >/dev/null && ! kubectl kustomize "$PLAT/infrastructure/$d" >/dev/null 2>&1; then
      echo "!! kubectl kustomize infrastructure/$d FAILED on $B. SKIPPING."
      git -C "$PLAT" checkout -q -- . ; git -C "$PLAT" clean -qfd ; FAILED=1; continue 2
    fi
  done
  echo "   platform repo: guards pass, kustomize builds"

  if [ -x "$(dirname "${BASH_SOURCE[0]}")/check-foreign-cluster-ids.sh" ]; then
    "$(dirname "${BASH_SOURCE[0]}")/check-foreign-cluster-ids.sh" "$PLAT" "$B" --diff "origin/$B" \
      || { echo "!! check-foreign-cluster-ids.sh flagged $B. SKIPPING."
           git -C "$PLAT" checkout -q -- . ; git -C "$PLAT" clean -qfd ; FAILED=1; continue; }
  else
    echo "   (check-foreign-cluster-ids.sh not executable -- foreign ids NOT checked)"
  fi

  git -C "$PLAT" add -A infrastructure/rbac infrastructure/aws-iam-authenticator
  git -C "$PLAT" commit -q -m "INFRA-1638: AWS SSO cluster access for $CID

Adds infrastructure/rbac (the group-keyed ClusterRoleBindings) and
infrastructure/aws-iam-authenticator (the webhook server and kube-system/aws-auth),
mirroring what has run on op-usxpress-qa since 2026-07-28. Neither directory
existed on this branch.

The SSO role ARN is read back from account $ACCT, not copied: the permission set
usx-on-prem-admins is provisioned to all three accounts but AWS generates a
different suffix per account. A copied ARN does not error -- the caller
authenticates as system:anonymous and everything returns forbidden.

rbac/ is delivered FIRST. aws-auth names the group onprem-platform-admins; without
the binding, SSO authenticates correctly and authorises nothing.

The kube-apiserver webhook flag is NOT here. That is Talos machine config in
iaac-talos, promoted through Octopus, and it must land after this is running."

  echo
  echo "-------- $PLAT: git diff origin/$B --------"
  git -C "$PLAT" --no-pager diff "origin/$B" --stat
  git -C "$PLAT" --no-pager diff "origin/$B"
  echo "-------- end --------"

  # ---------------------------------------------------------------- repo 2 --
  git -C "$CLUS" checkout -q -B "$TOPIC-$CDIR" origin/master \
    || { echo "!! cluster-repo checkout failed"; FAILED=1; continue; }
  INFRA="$CLUS/clusters/$CDIR/flux-system/infra.yaml"
  if [ ! -f "$INFRA" ]; then
    echo "!! no $INFRA. SKIPPING the wiring half."; FAILED=1; continue
  fi
  if grep -q 'name: aws-iam-authenticator' "$INFRA"; then
    echo "!! $CDIR already wires aws-iam-authenticator -- refusing to append twice."
    FAILED=1; continue
  fi

  cat >> "$INFRA" <<'EOF'
---
# INFRA-1638 — per-user cluster access via AWS SSO.
#
# rbac FIRST: aws-auth below maps the SSO role to the group onprem-platform-admins,
# and that group is bound here. Without the binding SSO authenticates correctly and
# authorises nothing, which presents as "logged in, everything forbidden".
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: rbac
  namespace: flux-system
spec:
  interval: 10m0s
  retryInterval: 5m0s
  path: ./infrastructure/rbac
  prune: true
  sourceRef:
    kind: GitRepository
    name: infra
  wait: true
  timeout: 2m0s
---
# The authenticator server plus kube-system/aws-auth. dependsOn rbac so the groups
# exist before anything is mapped onto them. op-usxpress-qa omits this dependency;
# it is added here because the ordering is real even though the apply succeeds
# either way.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: aws-iam-authenticator
  namespace: flux-system
spec:
  interval: 10m0s
  retryInterval: 5m0s
  path: ./infrastructure/aws-iam-authenticator
  prune: true
  sourceRef:
    kind: GitRepository
    name: infra
  wait: true
  timeout: 5m0s
  dependsOn:
    - name: rbac
EOF

  python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" "$INFRA" 2>/dev/null \
    || { echo "!! $INFRA no longer parses. SKIPPING."
         git -C "$CLUS" checkout -q -- . ; FAILED=1; continue; }
  echo "   cluster repo: yaml parses"

  git -C "$CLUS" add -A "clusters/$CDIR/flux-system/infra.yaml"
  git -C "$CLUS" commit -q -m "INFRA-1638: wire rbac and aws-iam-authenticator on $CID

Delivers the two directories added to iaac-talos-flux-platform branch $B. Neither
Kustomization existed on this cluster; op-usxpress-qa has had both since
2026-07-28.

aws-iam-authenticator dependsOn rbac. QA does not declare it, but aws-auth maps
the SSO role onto the group onprem-platform-admins and that group is bound by
rbac -- apply order does not affect success, it affects whether the first person
to log in can do anything."

  echo
  echo "-------- $CLUS: git diff origin/master --------"
  git -C "$CLUS" --no-pager diff origin/master
  echo "-------- end --------"

  if [ "$PUSH" = "yes" ]; then
    BODY="Part of INFRA-1638. op-usxpress-qa has had AWS SSO cluster access since 2026-07-28; \`$CID\` has neither \`infrastructure/rbac\` nor \`infrastructure/aws-iam-authenticator\`, and no Flux Kustomization for either.

**The SSO role ARN is read back, not copied.** The permission set \`usx-on-prem-admins\` is provisioned to all three accounts, but AWS generates a different suffix per account (\`aws iam list-roles\`, 2026-08-24):

| cluster | account | role |
|---|---|---|
| dev | 700736442855 | \`AWSReservedSSO_usx-on-prem-admins_b7447c115978d407\` |
| qa | 527101283767 | \`AWSReservedSSO_usx-on-prem-admins_8c7f139e431625e0\` |
| prod | 937464026810 | \`AWSReservedSSO_usx-on-prem-admins_837df2a43495aaf1\` |

A copied ARN **does not error**. The caller authenticates as \`system:anonymous\` and every request returns \`forbidden\`, which reads exactly like an RBAC bug. Same for the path: \`list-roles\` returns \`role/aws-reserved/sso.amazonaws.com/...\` and the authenticator canonicalises **without** the path.

**\`rbac\` is delivered first and the authenticator \`dependsOn\` it.** \`aws-auth\` maps the role onto group \`onprem-platform-admins\`; without the binding, SSO authenticates correctly and authorises nothing.

**Not in this PR:** the kube-apiserver \`--authentication-token-webhook-config-file\` flag. That is Talos machine config in \`iaac-talos\`, promoted through Octopus only, and it must land **after** this is running — the reverse order stops the apiserver from starting.

**Verify after merge** — and not by \`Ready=True\`, which only says the manifests applied:
\`\`\`
kubectl --context admin@$CID -n kube-system get pods -l k8s-app=aws-iam-authenticator
kubectl --context admin@$CID -n kube-system get configmap aws-auth -o yaml
\`\`\`
then, once the Talos flag is in, an actual \`aws sso login\` and a \`kubectl auth whoami\` as an SSO user. The x509 admin kubeconfig stays as break-glass and must be confirmed working before the flag lands."

    if git -C "$PLAT" push -q -u origin "$TOPIC-$B"; then
      gh pr create --repo variant-inc/iaac-talos-flux-platform \
        --base "$B" --head "$TOPIC-$B" \
        --title "INFRA-1638: AWS SSO cluster access for $CID (rbac + aws-iam-authenticator)" \
        --body "$BODY" || echo "   !! gh pr create failed for $PLAT $B"
    else
      echo "   !! push failed for $PLAT $B"; FAILED=1
    fi

    if git -C "$CLUS" push -q -u origin "$TOPIC-$CDIR"; then
      gh pr create --repo variant-inc/iaac-talos-flux-cluster \
        --base master --head "$TOPIC-$CDIR" \
        --title "INFRA-1638: wire rbac + aws-iam-authenticator on $CID" \
        --body "$BODY

⚠️ **Merge order:** the platform PR (manifests) first, this one (wiring) second. Flux will report the Kustomization \`Ready=False\` until the paths exist." \
        || echo "   !! gh pr create failed for $CLUS $CDIR"
    else
      echo "   !! push failed for $CLUS $CDIR"; FAILED=1
    fi
  fi
done

git -C "$PLAT" checkout -q - 2>/dev/null
git -C "$CLUS" checkout -q - 2>/dev/null
echo
[ "$PUSH" = "yes" ] || echo "Nothing pushed. Read the diffs, then re-run with --push."
[ "$FAILED" -eq 0 ] || { echo "One or more targets were skipped."; exit 1; }
