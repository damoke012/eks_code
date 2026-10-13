#!/usr/bin/env bash
# Stage the console cluster-version fix for ONE environment.
#   bash stage-console-version-sync-pr.sh dev|qa|prod
#   BUMP_IMAGE=1 ...   also move the console image to v0.7.9 by digest
#
# Clones fresh, edits, asserts every match is unique, validates the YAML, prints
# the diff and STOPS. Nothing is pushed.
#
# Measured 2026-10-13: cluster_connection_info.version read v2.8.2 on every org
# row in all three environments (dev 8, QA 5, prod 1) while the engine ran
# v3.0.5. The console writes that row ONLY when it is absent, so correcting
# init.yaml alone changes nothing live -- hence the sync-cluster-version init
# container, which reads the version from the same ConfigMap and reconciles it.
#
# dev was fixed by iaac-risingwave-onprem#52 (merged 2026-10-13), image included.
# QA and prod default to the version fix WITHOUT the image bump: dev has to soak
# on v0.7.9 first. Set BUMP_IMAGE=1 once it has.
set -euo pipefail

ENV="${1:-}"
case "$ENV" in
  dev|qa|prod) ;;
  *) echo "usage: $0 dev|qa|prod   (BUMP_IMAGE=1 to also move the console image)"; exit 1 ;;
esac

REPO=variant-inc/iaac-risingwave-onprem
WORK=/tmp/console-sync-$ENV-$$
BR="fix/console-cluster-version-$ENV"
DIGEST=sha256:12f4d5134e8f9315c06fc172f5db4a839b93ff788c05eb2c6889e3c93cd19b8f
PGPIN=postgres@sha256:7958605b474b3d264a969cb3a123d6aa00ad1e1fe9da8a69984dabb704d93317
BUMP_IMAGE="${BUMP_IMAGE:-0}"

rm -rf "$WORK"
gh repo clone "$REPO" "$WORK" -- -q --depth 1 --branch main
cd "$WORK"
git checkout -q -b "$BR"

F="manifests/op-usxpress-$ENV/risingwave-console.yaml"
[ -f "$F" ] || { echo "ABORT: $F does not exist"; exit 1; }

python3 - "$F" "$DIGEST" "$PGPIN" "$BUMP_IMAGE" <<'PY'
import sys
f, digest, pgpin, bump = sys.argv[1:5]
s = open(f).read()

def once(hay, needle, what):
    n = hay.count(needle)
    if n != 1:
        sys.exit(f"ABORT: expected exactly 1 {what}, found {n}")

once(s, "version: v2.8.2", "'version: v2.8.2' in the manifest")
s = s.replace("version: v2.8.2", "version: v3.0.5")

if bump == "1":
    old = "image: risingwavelabs/risingwave-console:v0.7.4"
    once(s, old, "console image line")
    s = s.replace(old, f"image: risingwavelabs/risingwave-console@{digest}")
    print("console image bumped to v0.7.9 by digest")
else:
    print("console image left at v0.7.4 (set BUMP_IMAGE=1 to move it)")

# Anchor on the render-config container, not on a comment: the comment wording
# differs between environments, and in QA this also places the new container
# AFTER sync-orgs, so a row sync-orgs has just copied is corrected too.
anchor = "        - name: render-config"
once(s, anchor, "render-config init container")
block = f"""        # Keep the console's recorded cluster version in step with the engine.
        # The console writes cluster_connection_info from init.yaml ONLY when the
        # row is absent, so an engine upgrade leaves every org showing the old
        # version for ever. Measured 2026-10-13: every org row read v2.8.2 while
        # the cluster ran v3.0.5. Reads the version from the same ConfigMap the
        # console uses, so there is one source of truth. Idempotent.
        - name: sync-cluster-version
          image: {pgpin}
          command:
            - sh
            - -c
            - |
              V=$(sed -n 's/^[[:space:]]*version:[[:space:]]*//p' /init-config/init.yaml | head -1)
              if [ -z "$V" ]; then
                echo "sync-cluster-version: no version in init.yaml -- NOT a no-op, failing"
                exit 1
              fi
              DSN="postgres://${{PG_USERNAME}}:${{PG_PASSWORD}}@pg-postgresql.risingwave.svc.cluster.local:5432/metadata"
              HAS=$(psql "${{DSN}}" -v ON_ERROR_STOP=1 -tAc "
                SELECT count(*) FROM information_schema.tables
                WHERE table_schema='public' AND table_name='cluster_connection_info'")
              if [ "$HAS" != "1" ]; then
                echo "sync-cluster-version: table absent, first install -- skipping"
                exit 0
              fi
              psql "${{DSN}}" -v ON_ERROR_STOP=1 -c \\
                "UPDATE cluster_connection_info SET version='$V', updated_at=NOW()
                  WHERE version IS DISTINCT FROM '$V'"
              echo "sync-cluster-version: rows now ->"
              psql "${{DSN}}" -tAc "SELECT org_id, version FROM cluster_connection_info ORDER BY org_id"
          env:
            - name: PG_USERNAME
              valueFrom:
                secretKeyRef:
                  name: pg-credentials
                  key: username
            - name: PG_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: pg-credentials
                  key: password
          securityContext:
            runAsUser: 999
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: init
              mountPath: /init-config

"""
s = s.replace(anchor, block + anchor, 1)
open(f, "w").write(s)
print("edits applied, each asserted unique")
PY

# The init container mounts the `init` volume as a DIRECTORY. That only yields
# /init-config/init.yaml if the volume is a plain configMap with no items list.
if grep -A2 '^            - name: init$' "$F" | grep -q 'items:'; then
  echo "ABORT - the init volume uses an items list; /init-config/init.yaml may not exist"
  exit 1
fi
echo "init volume is a plain configMap - /init-config/init.yaml will resolve"

if python3 -c 'import yaml' 2>/dev/null; then
  python3 -c "
import yaml
docs = list(yaml.safe_load_all(open('$F')))
print(f'YAML OK - {len([d for d in docs if d])} documents parse')
" || { echo "ABORT - edited manifest is not valid YAML"; exit 1; }
else
  echo "NOT MEASURED - PyYAML absent, manifest not validated (this is not a failure)"
fi

echo
echo "================= DIFF ($ENV) ================="
git --no-pager diff
echo "==============================================="
echo
echo "Branch $BR in $WORK. NOTHING pushed."
echo "Dry-run it against the live cluster FIRST:"
echo "  kubectl --kubeconfig=\$HOME/.kube/<the $ENV kubeconfig> -n risingwave \\"
echo "    apply --dry-run=server -f $WORK/$F"
echo "Then:"
echo "  cd $WORK"
echo "  git add -A && git commit -m 'INFRA-1647: console reports v2.8.2 on $ENV while the cluster runs v3.0.5'"
echo "  git push -u origin $BR"
echo "  gh pr create --repo $REPO --base main --fill"
