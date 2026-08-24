#!/usr/bin/env bash
# INFRA-1661 — turn on the kube-apiserver aws-iam-authenticator webhook.
#
# The work already exists on variant-inc/iaac-talos branch feat/aws-iam-authenticator
# (head ca5479f) and has NEVER been merged or even raised as a PR. This rebases it onto
# master and adds dev.
#
# WHAT MERGING THIS ALSO FIXES: op-usxpress-qa has had working SSO since 2026-07-28 using
# `enable_aws_iam_authenticator = true` in qa.tfvars — which exists ONLY on that branch.
# A QA deploy from master today would silently drop the flag and remove SSO, with every
# status field green. That is INFRA-1662, and it closes as a side effect of this merge.
#
# THE REBASE IS MECHANICAL, verified 2026-08-24:
#   master's 4 extra commits touch  deploy/terraform/modules/irsa/...
#   the branch touches              deploy/terraform/modules/talos/..., envs/, main.tf
#   zero overlap. If the rebase conflicts anyway, this script ABORTS and changes nothing.
#
# PROD IS DELIBERATELY NOT INCLUDED. There is no deploy/terraform/envs/prod.tfvars, and
# `op-usxpress-prod` appears nowhere in that repository on any branch. There is no file to
# put the flag in. That is INFRA-1663 and must be answered — probably in Octopus — before
# prod can be enabled. Do NOT create a prod.tfvars on the assumption the pattern matches.
#
# ⚠️ ORDERING, from the variable's own description: kube-apiserver will NOT START if the
# webhook config file is missing. The DaemonSet must already be Running and have written
# /var/lib/aws-iam-authenticator/kubeconfig.yaml on EVERY control-plane node first.
# op-usxpress-dev satisfies this as of 2026-08-24 20:04 UTC — 3/3 pods, all CPs, 0 restarts.
# x509 auth is unaffected either way, so the admin kubeconfig stays the way back in.
#
# THIS SCRIPT DOES NOT APPLY ANYTHING. terraform apply for iaac-talos is Octopus only
# (CLAUDE.md rule 1). It opens a PR; a human merges; Octopus promotes.
#
#   scripts/pr-1661-apiserver-webhook.sh
#   scripts/pr-1661-apiserver-webhook.sh --push
set -uo pipefail

PUSH=no
[ "${1:-}" = "--push" ] && PUSH=yes

WORK="${WORK:-$HOME/pr-work/iaac-talos}"
SRC="origin/feat/aws-iam-authenticator"
TOPIC="infra-1661-apiserver-webhook"
VAR="enable_aws_iam_authenticator"

command -v gh >/dev/null || { echo "!! gh not on PATH" >&2; exit 2; }
[ -d "$WORK/.git" ] || { echo "!! no checkout at $WORK" >&2; exit 2; }
cd "$WORK" || exit 2
git fetch -q origin || { echo "!! fetch failed" >&2; exit 2; }

echo "repo: $WORK"
echo "base: origin/master"
echo "src:  $SRC"
echo "push: $PUSH"
echo

# --- refuse if prod somehow has a tfvars we did not expect ---------------------
if [ -e "deploy/terraform/envs/prod.tfvars" ]; then
  echo "!! deploy/terraform/envs/prod.tfvars now EXISTS."
  echo "   This script was written when it did not, and deliberately excludes prod"
  echo "   (INFRA-1663). Re-read before proceeding — the assumption behind the"
  echo "   exclusion has changed."
  exit 2
fi

git checkout -q -B "$TOPIC" "$SRC" || { echo "!! checkout failed"; exit 2; }

echo "-- rebasing onto origin/master --"
if ! git rebase origin/master; then
  echo
  echo "!! REBASE CONFLICTED. Aborting and changing nothing."
  echo "   The file lists did not overlap when this was written; something moved."
  echo "   Resolve by hand, with the module comment in mind: ONE apiServer patch"
  echo "   assembled from a merged map. Two patches both setting extraArgs rely on"
  echo "   Talos merging rather than replacing, and if it replaces, IRSA breaks."
  git rebase --abort
  exit 1
fi
echo "   rebase clean"

# --- guards on what the branch is supposed to contain --------------------------
BAD=0
grep -q "variable \"$VAR\"" deploy/terraform/variables.tf \
  || { echo "!! $VAR is not declared in deploy/terraform/variables.tf"; BAD=1; }
grep -q "^${VAR} *= *true" deploy/terraform/envs/qa.tfvars \
  || { echo "!! qa.tfvars does not set $VAR — this is not the branch expected"; BAD=1; }
grep -q 'authentication-token-webhook-config-file' deploy/terraform/modules/talos/main.tf \
  || { echo "!! the talos module does not set the webhook flag"; BAD=1; }
# The flag must take the HOST path. Both container logs print in-container paths and
# neither is right; /var/lib is the hostPath the DaemonSet mounts.
grep -q '"/var/lib/aws-iam-authenticator/kubeconfig.yaml"' deploy/terraform/modules/talos/main.tf \
  || { echo "!! the flag does not point at /var/lib/aws-iam-authenticator/kubeconfig.yaml"; BAD=1; }
if [ "$BAD" -ne 0 ]; then
  echo "   SKIPPING — nothing changed."
  git rebase --abort 2>/dev/null; git checkout -q - 2>/dev/null
  exit 1
fi
echo "   branch guards: variable declared, qa set, flag present, HOST path correct"

# --- add dev -------------------------------------------------------------------
if grep -q "^${VAR}" deploy/terraform/envs/dev.tfvars; then
  echo "   dev.tfvars already sets $VAR — leaving it alone"
else
  # dev.tfvars may not end with a newline; appending blind would glue the line onto
  # the last one. That exact bug deleted a Kustomization earlier today.
  [ -n "$(tail -c1 deploy/terraform/envs/dev.tfvars)" ] && printf '\n' >> deploy/terraform/envs/dev.tfvars
  cat >> deploy/terraform/envs/dev.tfvars <<'EOF'

# INFRA-1661 — point kube-apiserver at the aws-iam-authenticator webhook.
# PRECONDITION, and it is not optional: the DaemonSet must already be Running and have
# written /var/lib/aws-iam-authenticator/kubeconfig.yaml on EVERY control-plane node, or
# kube-apiserver will not start. Verified on op-usxpress-dev 2026-08-24 20:04 UTC —
# 3/3 pods on talos-cp-op-dev-1/2/3, 0 restarts. x509 auth is unaffected either way.
enable_aws_iam_authenticator = true
EOF
  echo "   dev.tfvars: $VAR = true added"
fi

N=$(grep -c "^${VAR} *= *true" deploy/terraform/envs/dev.tfvars)
[ "$N" -eq 1 ] || { echo "!! dev.tfvars sets $VAR $N times, expected exactly 1"
                    git checkout -q -- . ; git checkout -q - 2>/dev/null; exit 1; }

if command -v terraform >/dev/null; then
  # WRITE, not just check. The branch's own qa.tfvars line is unaligned, and so is
  # ours until fmt runs. Leaving it is a CI failure on a PR whose diff is supposed
  # to be readable.
  terraform fmt -recursive deploy/terraform >/dev/null 2>&1
  if terraform fmt -check -recursive deploy/terraform >/dev/null 2>&1; then
    echo "   terraform fmt: clean (fmt was applied if needed)"
  else
    echo "   !! terraform fmt still unhappy after writing:"
    terraform fmt -check -recursive deploy/terraform 2>&1 | sed 's/^/     /' | head
  fi
else
  echo "   (terraform not on PATH — fmt NOT checked, and the branch is known unaligned)"
fi

git add -A deploy/terraform
git commit -q -m "INFRA-1661: enable the apiserver webhook on op-usxpress-dev

The DaemonSet, kube-system/aws-auth and the platform RBAC went live on
op-usxpress-dev on 2026-08-24 (INFRA-1638) and are inert until kube-apiserver is
given --authentication-token-webhook-config-file. This sets the flag for dev.

Precondition satisfied before setting it: 3/3 authenticator pods Running on
talos-cp-op-dev-1/2/3 with 0 restarts, each having written
/var/lib/aws-iam-authenticator/kubeconfig.yaml. kube-apiserver does not start if
that file is missing. x509 auth is unaffected, so the admin kubeconfig remains
the way back in.

Prod is NOT included: there is no envs/prod.tfvars and op-usxpress-prod appears
nowhere in this repository on any branch (INFRA-1663)." || echo "   nothing to commit"

echo
echo "-------- git diff origin/master  (READ THIS IN FULL) --------"
git --no-pager diff origin/master --stat
echo
git --no-pager diff origin/master
echo "-------- end --------"

if [ "$PUSH" = "yes" ]; then
  if git push -q -u origin "$TOPIC" --force-with-lease; then
    gh pr create --repo variant-inc/iaac-talos --base master --head "$TOPIC" \
      --title "INFRA-1661: enable the aws-iam-authenticator apiserver webhook (dev), and get QA's flag onto master" \
      --body "Rebases \`feat/aws-iam-authenticator\` onto master and enables the webhook for **op-usxpress-dev**.

### This also fixes a live risk (INFRA-1662)

\`op-usxpress-qa\` has had working AWS SSO since **2026-07-28**. The flag that makes it work — \`enable_aws_iam_authenticator = true\` in \`envs/qa.tfvars\`, plus the module change — exists **only on the unmerged branch**:

\`\`\`
git branch -r --merged origin/master | grep -c aws-iam-authenticator   ->  0
grep -rn 'authentication-token-webhook-config-file' on master          ->  nothing
\`\`\`

A QA deploy from master today would silently drop the flag and remove SSO, with every status field green and x509 still working — so it would present as \"SSO stopped\" with no recent change to point at. Merging this puts the running configuration back in the mainline.

### The rebase

master's 4 extra commits touch \`modules/irsa/\` only; the branch touches \`modules/talos/\`, \`envs/\` and \`main.tf\`. **Zero file overlap.** The script aborts rather than resolving anything if that stops being true.

### The flag takes the HOST path

\`/var/lib/aws-iam-authenticator/kubeconfig.yaml\`. Three paths appear in this system and only that one is right — the init container's log says \`/etc/kubernetes/...\` (upstream generic, wrong on Talos, OS-managed) and the server's says \`/var/aws-iam-authenticator/...\` (in-container). The module already says so: \`# HOST path. The authenticator's own log prints the in-container path; not this one.\`

### Ordering — the precondition is not optional

kube-apiserver **will not start** if the webhook config file is missing. The DaemonSet must already be Running and have written the file on **every** control-plane node. Verified on op-usxpress-dev 2026-08-24 20:04 UTC: 3/3 pods on \`talos-cp-op-dev-1/2/3\`, \`RESTARTS 0\`. x509 auth is unaffected either way, so the admin kubeconfig stays as break-glass.

### Prod is not in this PR

There is no \`envs/prod.tfvars\`, and \`op-usxpress-prod\` appears nowhere in this repository on any branch — \`git log --all -S 'op-usxpress-prod' -- deploy/\` returns nothing. Prod's authenticator is running (INFRA-1638) but there is no file here to set its flag in. **INFRA-1663** must answer where prod's machine config comes from first; the likely answer is Octopus variables, and that should be confirmed rather than assumed.

### ⚠️ This PR is bigger than its title — read the whole diff

Rebasing the branch brings **everything else on it** too. All of it has been running on op-usxpress-qa since 2026-07-28, so this brings master in line with reality rather than introducing anything new — but it should be reviewed, not waved through:

| Change | Why it matters |
|---|---|
| `deploy.ps1` +91 lines | SM secret-wrapper seeding before the first `enable_irsa` apply, and a **two-pass Flux bootstrap** (CRDs must be Established before the CRs apply) plus seeding the `flux-system` git secret. Greenfield deploys behave differently after this. |
| `octopus/bento-import.py` | **Removes a hardcoded password** from the repo and requires `BENTO_PASSWORD` from the environment. Good change; note it fails closed if the secret is missing. |
| `.github/workflows/onboard-app.yaml` | Passes `BENTO_PASSWORD` through, paired with the above. |
| `octopus/apply-bootstrap-perms.sh` | **Widens an IAM policy** from `role/iaac-octopus-worker-${CLUSTER_NAME}` to `role/*-${CLUSTER_NAME}` and `role/*-${CLUSTER_NAME}-*`. This is a permissions broadening on the bootstrap role and is the one item here that deserves a deliberate yes or no. |

If any of that should land separately, say so and it can be split — but note that leaving it unmerged is what created INFRA-1662 in the first place.

### Acceptance

Not \"the plan applied\". On op-usxpress-dev, after Octopus promotes:
\`\`\`
aws sso login --profile usx-dev
kubectl auth whoami     # expect sso:<email>, group onprem-platform-admins
\`\`\`
A wrong ARN does not error — the caller becomes \`system:anonymous\` and everything returns \`forbidden\`.

**Apply is Octopus only.** Nothing was applied to build this PR." \
      || echo "   !! gh pr create failed"
  else
    echo "   !! push failed"
  fi
fi

git checkout -q - 2>/dev/null
echo
[ "$PUSH" = "yes" ] || echo "Nothing pushed. Read the diff, then re-run with --push."
