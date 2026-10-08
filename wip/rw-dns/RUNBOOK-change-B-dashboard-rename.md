# Change B — make `risingwave-dashboard.op-dev` mean the dashboard

**Measured 2026-10-08 on op-usxpress-dev. Nothing here has been run.**

PR #166 did this with a one-line routing change and killed SSO within the hour; #167 reverted
it. This is the version that accounts for why.

## What actually pins the hostname — three config values, not a route

| # | Where | Current value |
|---|---|---|
| 1 | `cm/risingwave-console-dex` → `config.yaml` → `issuer` | `https://risingwave-dashboard.op-dev.usxpress.io/dex` |
| 2 | same file → connector `entra-dev` → `redirectURI` | `https://risingwave-dashboard.op-dev.usxpress.io/dex/callback` |
| 3 | `deploy/risingwave-console` env `RCONSOLE_SSO_DEX_ISSUERURL` | `https://risingwave-dashboard.op-dev.usxpress.io/dex` |

`RCONSOLE_SSO_DEX_INTERNALISSUERURL` is `http://localhost:5556/dex` — internal, untouched.

**Owner, confirmed by label not by assumption:**
`kustomize.toolkit.fluxcd.io/name=risingwave-onprem`, namespace `flux-system`. So the edit is
in **`variant-inc/iaac-risingwave-onprem`**, `manifests/op-usxpress-dev/`. The ConfigMap also
carries a stale `argocd.argoproj.io/tracking-id` annotation — a leftover, op-dev has zero Argo
Applications.

## 🔑 Why the sequencing is safe this time

`/dex/*` is **already served** on `risingwave-console.op-dev.usxpress.io`. The VirtualService
`risingwave/risingwave-console` declares three hosts against one catch-all route, so every
console hostname already carries `/dex` and `/auth`.

That means steps 1–3 land **before** the route change, and in the gap a user who starts at the
dashboard hostname is bounced to the console hostname and signs in there. **The migration
performs itself.** The route change is last, and only once nothing auth-related names the
dashboard host.

## ⚠️ The one thing that can still fail: a row in a 129-day-old database

`storage: {type: sqlite3, file: /dex-data/dex.db}`, and `/dex-data` is the **PVC**
`risingwave-console-data` (1Gi, `local-path`, bound 129d).

The console registers its own OAuth client over gRPC (`RCONSOLE_SSO_DEX_SELFREGISTERCLIENT=true`,
`GRPCADDR=127.0.0.1:5557`), so `redirect_uris` for client `risingwave-console` lives in that
database — **not in any manifest.** If the console calls `CreateClient` and treats
`already_exists` as success, the stale `…dashboard…/auth/sso/callback` URI persists and login
fails with **`redirect_uri did not match`** — which no config change fixes.

**This is unknown, not predicted.** Step B4 reads the console's own startup log to find out,
before any human tries to log in. Do not skip it and diagnose from the browser.

## Order of operations

### B0. Clone the repo — it is not on the WSL box

Verified absent 2026-10-08: `~/` has `iaac-risingwave-cicd`, `iaac-talos`,
`iaac-talos-flux-cluster`, but **not** `iaac-risingwave-onprem`.

```bash
cd ~ && gh repo clone variant-inc/iaac-risingwave-onprem
cd ~/iaac-risingwave-onprem && git log --oneline -3
```

### B1. Entra first — it is purely additive and safe alone

App reg **`e112d6ce-cc60-4884-9898-8fcc5b78b0b1`** serves **dev, QA and prod**; only the
redirect URI differs per environment. **Add one, never replace the list**
([[rw-dex-entra-shared-app-registration]]).

```bash
APP=e112d6ce-cc60-4884-9898-8fcc5b78b0b1
NEW=https://risingwave-console.op-dev.usxpress.io/dex/callback
OLD=$(az ad app show --id $APP --query 'web.redirectUris' -o tsv | tr '\n' ' ')
N=$(echo $OLD | wc -w)
echo "BEFORE ($N):"; for u in $OLD; do echo "  $u"; done
echo "WILL ADD: $NEW"
```

Read that list. Then, only if `$NEW` is not already in it:

```bash
az ad app update --id $APP --web-redirect-uris $OLD $NEW
M=$(az ad app show --id $APP --query 'web.redirectUris' -o tsv | wc -l)
echo "AFTER: $M (must be exactly $((N + 1)))"
az ad app show --id $APP --query 'web.redirectUris' -o tsv
```

**If `AFTER` is not `BEFORE + 1`, stop and restore the printed list.** A short list means QA or
prod lost its URI. Nothing else in this runbook has run yet, so there is nothing to unwind.

### B2. Record the Dex baseline

```bash
K=~/.kube/op-usxpress-dev-fresh.yaml
C=admin@op-usxpress-dev
curl -s --resolve risingwave-console.op-dev.usxpress.io:443:10.10.82.21 \
  https://risingwave-console.op-dev.usxpress.io/dex/.well-known/openid-configuration \
  | python3 -m json.tool | grep -iE 'issuer|authorization_endpoint|token_endpoint'
kubectl --kubeconfig $K --context $C -n risingwave get pod \
  -l app.kubernetes.io/name=risingwave-console -o name
```

Expect `issuer` to echo the **dashboard** hostname. That is the before-value.

### B3. Edit the three values, PR, merge

```bash
cd ~/iaac-risingwave-onprem
git fetch origin && git checkout -B rw/console-issuer origin/main
grep -rn 'risingwave-dashboard\.op-dev' manifests/op-usxpress-dev/
```

Replace `risingwave-dashboard.op-dev.usxpress.io` with
`risingwave-console.op-dev.usxpress.io` **only** at the three sites above, then:

```bash
# scope gate -- this repo has NO promotion gate, merging IS deploying to prod
git diff origin/main --stat
git diff origin/main --name-only | grep -v '^manifests/op-usxpress-dev/' \
  && echo "ABORT -- the diff leaves the dev directory" \
  || echo "scope OK -- dev only"
git diff origin/main
```

⚠️ Every cluster's Flux `GitRepository` tracks `branch: main` at **5 minutes**. There is no
Octopus release and no TfApply gate — **the only thing keeping this off QA and prod is that
directory boundary** ([[risingwave-onprem-has-no-promotion-gate]]). The grep above must print
`scope OK`.

### B3b. ⛔ CORRECTED — after merge, prove the Kustomization APPLIED

Two things the earlier draft got wrong.

**1. Do not `rollout restart`.** The diff changes `RCONSOLE_SSO_DEX_ISSUERURL` in the **pod
template**, so the merge produces a new ReplicaSet on its own. A manual restart races Flux
and muddies which revision the running pod came from.

**2. A merged PR is not an applied change.** This exact Deployment froze a whole
Kustomization for **4 hours with no alert** on a server-side-apply conflict —
`strategy: Recreate` could not apply over a live `rollingUpdate` block (PR #36,
[[server-side-apply-keeps-dropped-fields]]). "Merged" looked like "applied". And this repo has
no Alertmanager on-prem to say otherwise.

So walk all four layers, finishing at the pod ([[gitops-has-four-stale-layers]]):

```bash
K=~/.kube/op-usxpress-dev-fresh.yaml
C=admin@op-usxpress-dev
M=$(cd ~/iaac-risingwave-onprem && git rev-parse origin/main | cut -c1-8)
echo "merge commit: $M"
kubectl --kubeconfig $K --context $C -n flux-system get gitrepository   iaac-risingwave-onprem -o jsonpath='{.status.artifact.revision}{"\n"}'
kubectl --kubeconfig $K --context $C -n flux-system get kustomization   risingwave-onprem   -o jsonpath='READY={.status.conditions[?(@.type=="Ready")].status}{"  "}{.status.conditions[?(@.type=="Ready")].message}{"\n"}APPLIED={.status.lastAppliedRevision}{"\n"}'
```

`READY=True` **and** `lastAppliedRevision` carrying the merge commit. Anything else — a
`False`, a stale revision, a dry-run error in the message — means it did not apply, and no
amount of pod-watching will reveal that.

Then prove it reached the live object, not just the revision:

```bash
K=~/.kube/op-usxpress-dev-fresh.yaml
C=admin@op-usxpress-dev
kubectl --kubeconfig $K --context $C -n risingwave get cm   risingwave-console-dex -o jsonpath='{.data.config\.yaml}' | grep -E '^ *issuer:'
kubectl --kubeconfig $K --context $C -n risingwave get pod   -l app.kubernetes.io/name=risingwave-console   -o custom-columns='NAME:.metadata.name,START:.status.startTime,READY:.status.phase'
```

The ConfigMap must read `risingwave-console`, and the pod `startTime` must be **after** the
merge. An old `startTime` with a new ConfigMap means the mounted config changed under a
process that never re-read it ([[config-can-outrun-the-image]]).

### B4. Read the self-registration log BEFORE any browser

```bash
K=~/.kube/op-usxpress-dev-fresh.yaml
C=admin@op-usxpress-dev
kubectl --kubeconfig $K --context $C -n risingwave rollout restart \
  deploy/risingwave-console
kubectl --kubeconfig $K --context $C -n risingwave rollout status \
  deploy/risingwave-console --timeout=180s
kubectl --kubeconfig $K --context $C -n risingwave logs \
  deploy/risingwave-console -c risingwave-console --tail=200 \
  | grep -iE 'dex|client|register|redirect|issuer'
kubectl --kubeconfig $K --context $C -n risingwave logs \
  deploy/risingwave-console -c dex --tail=200 \
  | grep -iE 'client|redirect|issuer|error'
```

Then confirm the issuer actually moved:

```bash
curl -s --resolve risingwave-console.op-dev.usxpress.io:443:10.10.82.21 \
  https://risingwave-console.op-dev.usxpress.io/dex/.well-known/openid-configuration \
  | python3 -c 'import json,sys; print("issuer:", json.load(sys.stdin)["issuer"])'
```

**This is the decision point.** If the logs show the client was re-registered or updated,
continue to B5. If they show `already_exists`, a skip, or nothing at all, go to B6 first —
the database still holds the old callback.

### B5. A human signs in — the only valid value

Open `https://risingwave-console.op-dev.usxpress.io/`, click **Sign in with SSO**, land
signed in.

`curl` cannot close this. `/dex/auth` returned **200 before any change was made**, so a
status-code check would pass while the flow is broken — the adjacent-green-signal family
([[adjacent-step-green-signals]]). Nothing proceeds on a 200.

### B6. Only if B4 shows a stale client — recreate Dex's data

The stale row is in the PVC. Changing the issuer has **already** invalidated every session and
refresh token, so the sqlite contents are worth little at this point: Dex regenerates its
signing keypair on start, and the Entra connector means there are no local passwords to lose
(`enablePasswordDB: true` is on, but no `staticPasswords` are configured).

**Confirm that is still true before deleting anything:**

```bash
K=~/.kube/op-usxpress-dev-fresh.yaml
C=admin@op-usxpress-dev
kubectl --kubeconfig $K --context $C -n risingwave get cm \
  risingwave-console-dex -o jsonpath='{.data.config\.yaml}' \
  | grep -iE 'staticPasswords|staticClients|enablePasswordDB' -A4
```

If `staticPasswords` has entries, **stop** — they are only in that database and deleting it
destroys them. Otherwise scale down, clear the file, scale up:

```bash
kubectl --kubeconfig $K --context $C -n risingwave scale \
  deploy/risingwave-console --replicas=0
kubectl --kubeconfig $K --context $C -n risingwave scale \
  deploy/risingwave-console --replicas=1
```

⚠️ A scale cycle alone does **not** clear a PVC. Removing `/dex-data/dex.db` needs either a
one-shot pod mounting `risingwave-console-data`, or deletion of the PVC so `local-path`
reprovisions it. **Neither is drafted here, deliberately** — it destroys data in Tim's
namespace and belongs in its own reviewed change with his agreement, not as a footnote. If
B4 lands here, stop and raise it.

### B7. Repoint the dashboard hostname — last

`variant-inc/iaac-talos-flux-platform`, branch `op-dev`,
`infrastructure/risingwave-routes/virtualservice-dashboard.yaml`:
`risingwave-console.risingwave.svc.cluster.local:8020` → `risingwave-meta:5691`.

### B8. Verify against the recorded baseline

Re-run `wip/rw-dns/BASELINE-2026-10-08-before-change-B.md`'s command. **Pass is all four:**

1. `risingwave-dashboard` body sha256 == `cc738d9a03a28c9a` — it moved to the meta dashboard
2. `risingwave-dashboard` != `9980ad26c2748234` — no longer the console
3. `risingwave-console` == `9980ad26c2748234` — unchanged
4. A human signs in at `risingwave-console.op-dev` **again**, after B7

## Rollback

Revert the one file, as #167 did, and re-run B8. **Do not debug forward on a hostname that
carries someone's login.** The Entra URI from B1 is additive and can stay — remove it only
once nothing uses it.

## Gates before any of this

* **Tim's nod.** `risingwave` on op-dev is his namespace and this changes the URL he signs in
  through.
* **B1 before B3.** Entra must accept the new `/dex/callback` before Dex starts sending users
  to it.
* **B4 before B5.** Read the log before the browser, or a `redirect_uri` mismatch reads as
  "SSO is broken" with no cause attached.
