# Runbook — finish the on-prem DNS work

Two changes left. **A** is a tidy-up gated on Tim. **B** is a rename gated on Entra.
Both land in `variant-inc/iaac-talos-flux-platform`, branch **`op-dev`**, and both are
run on **WSL against corp GHE** — never from the codespace
([[usx-github-enterprise-not-personal]]).

**Run the measurement first.** It is read-only and it tells you whether anything moved
since 2026-10-08:

```bash
bash scripts/onprem-dns-finish.sh dev qa prod
```

---

## ⛔ Two traps that apply to every step below

**1. Build the PR from the branch, never from `wip/`.** The copies under
`wip/infra-1527-*` and `wip/rw-dns/` are drafts and at least one is stale. Copying a
`wip/` file over a branch silently reverted an ApplicationSet's Git URL on 2026-08-20
and broke delivery for 18 hours with every status field green.

**2. `infrastructure/risingwave-routes/kustomization.yaml` ENUMERATES its resources.**
Deleting a VirtualService file while its line stays in `kustomization.yaml` does not
remove one route — it **fails the kustomize build, so the whole Kustomization stops
applying** and every route in the directory freezes at its last-applied state. Delete
the file and its line in the same commit, and prove it with `kustomize build` before
pushing.

---

## Change A — collapse four console hostnames to one

Today op-dev serves one console UI under four names and the meta dashboard under one.

| Hostname | Serves | Disposition |
|---|---|---|
| `risingwave-console.op-dev` | console | **keep** — the correct name |
| `risingwave-dashboard.op-dev` | console | **keep for now** — Dex is mounted here; Change B owns it |
| `risingwave-web.op-dev` | console | **delete** |
| `risingwave.op-dev` | console | **delete** |
| `risingwave-overview.op-dev` | meta dashboard | **keep until Change B**, then delete |

### A0. Gate — Tim's nod, before the merge

`risingwave` on op-dev is Tim's namespace. Deleting `risingwave-web.op-dev` and
`risingwave.op-dev` removes URLs that may be bookmarked. Confirm he is on
`risingwave-console.op-dev.usxpress.io` and that nothing of his hardcodes the others.
His word comes before the merge, not after ([[promotion-order-qa2-dev-qa-prod]]).

### A1–A3. ⛔ CORRECTED 2026-10-08 — it is ONE VirtualService with three hosts

Measured on op-usxpress-dev:

```
risingwave/risingwave-console | risingwave-console.op-dev.usxpress.io,
                                risingwave.op-dev.usxpress.io,
                                risingwave-web.op-dev.usxpress.io
```

**All three console names are `spec.hosts` entries on a single VirtualService.** The
earlier version of this section assumed two separate files to `git rm`, each with a
`kustomization.yaml` line. That was wrong, and it was never measured — it was inferred
from the three names having appeared on three different days.

Consequences:

* The change is **two lines deleted from one file's `hosts:` list**. No file is removed.
* `kustomization.yaml` is **not touched**, so the enumerate-the-resources trap does not
  apply to Change A at all. It still applies to A5/B5, which do delete a file.
* The old A3 script would have aborted rather than done damage — its
  `[ "$(… | grep -c .)" -eq 2 ]` guard would have found 1 file and stopped. A guard that
  fires is the only reason this is a correction and not an incident.

### A1. Confirm the live state still matches, and find the file

```bash
kubectl --context admin@op-usxpress-dev -n risingwave \
  get virtualservice risingwave-console -o jsonpath='{.spec.hosts}'; echo

cd ~/src/iaac-talos-flux-platform
git fetch origin && git checkout -B dns/consolidate-rw-console origin/op-dev
grep -rln 'risingwave-web\.op-dev' infrastructure/
```

Expect exactly **one** file. If the grep returns two, the live state has changed since
this was measured — re-read it before editing.

### A2. Confirm the two doomed names carry nothing but the console

A single-route VirtualService carries **every** path, which is how PR #166 moved Dex. The
three hosts share one route here, so whatever is mounted under one is mounted under all
three:

```bash
kubectl --context admin@op-usxpress-dev -n risingwave \
  get virtualservice risingwave-console -o yaml | grep -nE 'hosts:|uri:|prefix:|host:|- risingwave'

kubectl --context admin@op-usxpress-dev -n risingwave \
  get deploy,cm -o yaml | grep -iE 'risingwave-web|risingwave\.op-dev|issuer|redirect|callback|_url'
```

The second grep must return **no reference to the two doomed names**. It *will* return
`risingwave-dashboard.op-dev` — that is the Dex issuer, and it is Change B's problem, not
Change A's. Deleting `risingwave-web` and `risingwave` does not touch it.

### A3. Remove the two hosts from the one file

```bash
cd ~/src/iaac-talos-flux-platform
D=infrastructure/risingwave-routes
F=$(grep -rln 'risingwave-web\.op-dev' "$D")
[ "$(echo "$F" | grep -c .)" -eq 1 ] || { echo "ABORT -- expected 1 file, got $(echo "$F" | grep -c .)"; exit 1; }
echo "editing: $F"

kustomize build "$D" > /tmp/routes-before.yaml || { echo "ABORT -- branch does not build"; exit 1; }
BEFORE=$(grep -c 'kind: VirtualService' /tmp/routes-before.yaml)

# drop exactly the two host lines; keep risingwave-console
sed -i '/- *risingwave-web\.op-dev\.usxpress\.io/d;/- *risingwave\.op-dev\.usxpress\.io/d' "$F"

# the keeper must survive, and the route COUNT must not change -- no file was removed
grep -q 'risingwave-console\.op-dev\.usxpress\.io' "$F" \
  && echo "keeper present" || { echo "ABORT -- sed ate the keeper"; exit 1; }
kustomize build "$D" > /tmp/routes-after.yaml || { echo "ABORT -- build broken"; exit 1; }
AFTER=$(grep -c 'kind: VirtualService' /tmp/routes-after.yaml)
[ "$AFTER" -eq "$BEFORE" ] || { echo "ABORT -- route count changed, expected $BEFORE got $AFTER"; exit 1; }

for h in risingwave-web risingwave-overview risingwave-dashboard risingwave-console; do
  printf '%-22s %s\n' "$h" "$(grep -c "$h.op-dev.usxpress.io" /tmp/routes-after.yaml)"
done
# expect: risingwave-web 0, the other three >= 1

git diff origin/op-dev
```

The `risingwave.op-dev` pattern is anchored on `- ` and a literal `.op-dev` so it cannot
match `risingwave-console.op-dev` or `risingwave-dashboard.op-dev`. The keeper check is
there because a `sed` that over-matches is the one failure this cannot detect by counting.

### A4. PR, merge, verify

```bash
git commit -m "dns: collapse four console hostnames to risingwave-console.op-dev

risingwave-web and risingwave.op-dev were minted on 2026-10-06 only because the
zone's 86400s negative TTL hid risingwave-console for a day after external-dns
created it. The cache has expired; risingwave-console resolves to all seven dev
workers. Both extra names are removed with their kustomization lines."
git push -u origin dns/consolidate-rw-console
gh pr create --base op-dev --fill
```

After the merge, Flux reconciles and `external-dns --policy=sync` deletes the two
records. Verify **the keepers still work**, which is the thing that can actually break:

```bash
for h in risingwave-console risingwave-dashboard risingwave-overview; do
  for ip in 10.10.82.21 10.10.82.180; do
    printf '%-22s %-13s http=%s verify=%s %s\n' "$h" "$ip" \
      "$(curl -s -o /dev/null -w '%{http_code}' --resolve "$h.op-dev.usxpress.io:443:$ip" "https://$h.op-dev.usxpress.io/")" \
      "$(curl -s -o /dev/null -w '%{ssl_verify_result}' --resolve "$h.op-dev.usxpress.io:443:$ip" "https://$h.op-dev.usxpress.io/")" \
      "$(curl -s --resolve "$h.op-dev.usxpress.io:443:$ip" "https://$h.op-dev.usxpress.io/" | sha256sum | cut -c1-16)"
  done
done

# and the SSO path, which is the one #166 broke
curl -s -o /dev/null -w 'dex=%{http_code}\n' \
  --resolve risingwave-dashboard.op-dev.usxpress.io:443:10.10.82.21 \
  'https://risingwave-dashboard.op-dev.usxpress.io/dex/auth'
```

`--resolve` bypasses DNS entirely, so it proves the route even while a resolver lies.
**Compare the body hashes** — `risingwave-console` and `risingwave-dashboard` must match
each other (both the console) and `risingwave-overview` must differ (the meta dashboard).
Three hashes settle the routing without parsing a page. `dex=200` is the gate.

---

## Change B — make `risingwave-dashboard` mean the dashboard

`risingwave-dashboard.op-dev` serves the **console** today, and that is load-bearing:
the console's Dex issuer and SSO callback are both pinned to that hostname. Repointing
the host alone was PR #166, and it 404'd "Sign in with SSO" within the hour.

**The order matters. Entra is step 2, and nothing after it can start early.**

### B1. Move the console's Dex issuer and SSO callback

Repo: `variant-inc/iaac-risingwave-onprem`, `manifests/op-usxpress-dev/`.

```bash
cd ~/src/iaac-risingwave-onprem
git fetch origin && git checkout -B dns/console-issuer origin/main
grep -rn 'risingwave-dashboard\.op-dev' manifests/op-usxpress-dev/
```

Change those occurrences to `risingwave-console.op-dev.usxpress.io` — the Dex `issuer`,
every `redirectURI`, and the console's own callback URL.

⚠️ **This repo has no promotion gate.** Every cluster's Flux `GitRepository` tracks
`branch: main` at 5 minutes, so **merging is deploying**. Living under
`manifests/op-usxpress-dev/` is the only thing keeping this off QA and prod — confirm
`git diff origin/main --stat` touches **nothing** outside that directory
([[risingwave-onprem-has-no-promotion-gate]]).

### B2. Add the redirect URI to the shared Entra app registration — ADD, never replace

ClientID `e112d6ce`. **The same app registration serves dev, QA and prod**, and only
the redirect URI differs per environment. Replacing the list breaks QA and prod
([[rw-dex-entra-shared-app-registration]]).

```bash
az ad app show --id e112d6ce --query 'web.redirectUris' -o json   # record this
```

Add `https://risingwave-console.op-dev.usxpress.io/auth/sso/callback` to the list the
command printed, keeping every existing entry, then re-read it and confirm the count
went **up by exactly one**.

This was believed to be blocked — "no Azure access". That was corrected on 2026-08-25
and an app-registration update is proven ([[onprem-human-access-model]]). It is
self-service.

### B3. Prove login on the new hostname, end to end

A human has to do this one. Open `https://risingwave-console.op-dev.usxpress.io/`,
click **Sign in with SSO**, and land signed in. `curl` cannot prove an OIDC round trip;
a 200 on `/dex/auth` proves the issuer is mounted, not that the flow completes.

**Do not start B4 until a human has signed in on the new name.**

### B4. Repoint `risingwave-dashboard` at the meta dashboard

This is PR #166 again, now that its two prerequisites exist. In
`iaac-talos-flux-platform` on `op-dev`, `infrastructure/risingwave-routes/virtualservice-dashboard.yaml`:
`risingwave-console.risingwave.svc.cluster.local:8020` → `risingwave-meta:5691`.

Verify by hash, immediately after the reconcile:

```
risingwave-console     -> console hash
risingwave-dashboard   -> meta hash      (must now DIFFER from console)
risingwave-overview    -> meta hash      (must MATCH dashboard)
```

Then re-check SSO on the new name: `/dex/auth` on **`risingwave-console.op-dev`** → 200.

**Roll back the way #167 did** — revert the one file — if either the hash or `dex` is
wrong. Do not debug forward on a hostname that carries someone's login.

### B5. Clean up

* Delete `risingwave-overview.op-dev` (now redundant with `risingwave-dashboard`), file
  **and** kustomization line, per trap 2.
* Remove the old redirect URI from Entra **only once nothing uses it** — after B3 and B4
  are both confirmed, not between them.
* Drop the two redundant per-host 443 server blocks from the `shared-http` Gateway. The
  `*.op-dev.usxpress.io` wildcard with `wildcard-op-dev-tls` already covers them — proven
  on 2026-10-06 when a brand-new hostname came up with `ssl_verify_result=0` and no
  Certificate and no Gateway edit.
* Normalise the API versions: `virtualservice-dashboard.yaml` is `networking.istio.io/v1`
  while `virtualservice-risingwave-console.yaml` is `v1beta1`.

---

## Change C — the zone's negative TTL

`wip/rw-dns/route53-soa-negative-ttl.md`. One field in the `usxpress.io` SOA, in network
account `155768531003`. **Not ours to change alone** — cloud shares the zone. Drafted
with its own blast-radius table; it needs the zone owner, not a PR.
