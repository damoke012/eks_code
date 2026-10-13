#!/usr/bin/env bash
# Stage the dev console fix. Clones fresh, edits, asserts, prints the diff, STOPS.
# Nothing is pushed. Run on WSL where corp GHE is reachable.
#
# Measured 2026-10-13: cluster_connection_info.version reads v2.8.2 on every org
# row in all three environments (dev 8, QA 5, prod 1) while the engine runs
# v3.0.5. The console seeds that row from init.yaml only when it is ABSENT, and
# neither init container updates it -- so correcting init.yaml alone changes
# nothing live. This adds an idempotent updater that reads the version from the
# same ConfigMap, so there is exactly one place the version is written.
set -euo pipefail

REPO=variant-inc/iaac-risingwave-onprem
WORK=/tmp/console-sync-$$
BR=fix/console-cluster-version-dev
DIGEST=sha256:12f4d5134e8f9315c06fc172f5db4a839b93ff788c05eb2c6889e3c93cd19b8f
PGPIN=postgres@sha256:7958605b474b3d264a969cb3a123d6aa00ad1e1fe9da8a69984dabb704d93317

rm -rf "$WORK"
gh repo clone "$REPO" "$WORK" -- -q --depth 1 --branch main
cd "$WORK"
git checkout -q -b "$BR"

F=manifests/op-usxpress-dev/risingwave-console.yaml
R=deploy/console-ui-enablement-runbook.md

python3 - "$F" "$R" "$DIGEST" "$PGPIN" <<'PY'
import sys
f, r, digest, pgpin = sys.argv[1:5]
s = open(f).read()

def once(hay, needle, what):
    n = hay.count(needle)
    if n != 1:
        sys.exit(f"ABORT: expected exactly 1 {what}, found {n}")

# 1. the declared cluster version
once(s, "version: v2.8.2", "'version: v2.8.2' in the manifest")
s = s.replace("version: v2.8.2", "version: v3.0.5")

# 2. console image -> pinned digest
old = "image: risingwavelabs/risingwave-console:v0.7.4"
once(s, old, "console image line")
s = s.replace(old, f"image: risingwavelabs/risingwave-console@{digest}")

# 3. the idempotent version updater, inserted before the render-config step
marker = "        # 2. Render config.yaml by substituting credentials into the template."
once(s, marker, "render-config marker comment")
block = f"""        # 1b. Keep the console's recorded cluster version in step with the engine.
        # The console writes cluster_connection_info from init.yaml ONLY when the
        # row is absent, so an engine upgrade leaves every org showing the old
        # version for ever. Measured 2026-10-13: all 8 dev orgs read v2.8.2 while
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
s = s.replace(marker, block + marker)
open(f, "w").write(s)

t = open(r).read()
# Match the closing backtick and full stop too, so the version annotation lands
# OUTSIDE the code span. Inside it, the line reads as a copy-pasteable image
# reference that is not valid -- a document that misleads is worse than a stale one.
oldr = "`risingwavelabs/risingwave-console:v0.7.4`."
once(t, oldr, "console image reference in the runbook")
t = t.replace(oldr, f"`risingwavelabs/risingwave-console@{digest}` (v0.7.9).")
open(r, "w").write(t)
print("all four edits applied, each asserted unique")
PY

# Refuse to produce a diff that is not parseable YAML. A broken manifest that
# reaches a PR fails at reconcile, where it freezes the whole Kustomization.
if python3 -c 'import yaml' 2>/dev/null; then
  python3 -c "
import sys, yaml
docs = list(yaml.safe_load_all(open('$F')))
print(f'YAML OK - {len([d for d in docs if d])} documents parse')
" || { echo "ABORT - edited manifest is not valid YAML"; exit 1; }
else
  echo "NOT MEASURED - PyYAML absent, manifest not validated (this is not a failure)"
fi

echo
echo "================= DIFF ================="
git --no-pager diff
echo "========================================"
echo
echo "Branch $BR in $WORK. NOTHING pushed."
echo "To raise it:"
echo "  cd $WORK"
echo "  git add -A && git commit -m 'INFRA-1647: console reports v2.8.2 while the cluster runs v3.0.5'"
echo "  git push -u origin $BR"
echo "  gh pr create --repo $REPO --base main --fill"
