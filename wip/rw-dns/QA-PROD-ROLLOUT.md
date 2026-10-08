# Console-hostname rollout — QA and prod

**Dev is complete (2026-10-08). QA is at step 2 of 6 and NOT blocked. Prod is untouched.**

The defect, in one line: `risingwave-dashboard.op-<env>` serves the **console**, and there is
no console-named hostname. Identical on all three clusters — body hashes were byte-identical,
so it is one defect in three places, not three variants.

| | dev | QA | prod |
|---|---|---|---|
| 1. `risingwave-console.op-<env>` VirtualService | ✅ (pre-existing) | ✅ **#169** | ☐ |
| 2. Entra `/dex/callback` URI added | ✅ | ✅ (list now 5) | ☐ |
| 3. Three config values moved | ✅ **onprem#40** | ☐ | ☐ |
| 4. Self-registration log + human login | ✅ 16:38 UTC | ☐ | ☐ |
| 5. Repoint `virtualservice-dashboard.yaml` | ✅ **#168** | ☐ | ☐ |
| 6. Hash gate + login again | ✅ | ☐ | ☐ |

## ⛔ NOT A BLOCKER — corrected. It was a reconcile in flight

```
first read   READY=False  APPLIED=op-qa@sha1:7acb311e
second read  READY=True   APPLIED=op-qa@sha1:b2b6cb37   since 2026-10-08T17:48:01Z
```

**The first read caught a reconcile in progress and I called it wedged**, wrote it into two
documents and halted the rollout on it. A `Ready=False` seconds old is a loop running; one
hours old is stuck, and only `lastTransitionTime` plus a second read tells them apart. My
probe printed neither. See [[gitops-has-four-stale-layers]].

Everything below this line was written under that wrong reading and is kept for the
reasoning, not the conclusion:

It has not completed an apply for **at least two commits**, and nothing alerted. The new
VirtualService from #169 is nevertheless live and serving the console
(`9980ad26c2748234`, `verify=0`) — Flux applied it and then failed elsewhere, and
`lastAppliedRevision` only advances on a *fully* successful run.

**Why this blocks step 5 and not step 3.** Step 3 edits
`manifests/op-usxpress-qa/risingwave-console.yaml`, owned by the **`risingwave-onprem`**
Kustomization from `iaac-risingwave-onprem` — unaffected. Step 5 edits
`infrastructure/risingwave-routes/`, owned by **this** Kustomization. A step-5 PR would
merge, go green in GitHub, and never reach the cluster; the hash test would then fail with
no cause attached.

**Not yet diagnosed.** Needed: the `Ready` condition's `reason` and `message`, its
`lastTransitionTime`, and the Kustomization's events. Likely pre-existing — `7acb311e`
predates both recent commits — in which case QA's RisingWave routes have been partly
unmanaged for an unknown period, which is a finding in its own right.

## QA steps 3–6, once unblocked

**3.** `variant-inc/iaac-risingwave-onprem`, `manifests/op-usxpress-qa/risingwave-console.yaml`
— replace `risingwave-dashboard.op-qa.usxpress.io` with `risingwave-console.op-qa.usxpress.io`
at exactly three sites, confirmed live on the cluster:

```
issuer: https://risingwave-dashboard.op-qa.usxpress.io/dex
redirectURI: https://risingwave-dashboard.op-qa.usxpress.io/dex/callback
RCONSOLE_SSO_DEX_ISSUERURL = https://risingwave-dashboard.op-qa.usxpress.io/dex
```

`RCONSOLE_SSO_DEX_INTERNALISSUERURL` is `http://localhost:5556/dex` — leave it.

⚠️ Scope the diff to `manifests/op-usxpress-qa/`. A merge to `main` in that repo reaches
**every** cluster ([[risingwave-onprem-has-no-promotion-gate]]), and it has **two** delivery
paths plus two permanently-red CI checks ([[risingwave-onprem-two-delivery-paths]]).

**4.** After the roll, read the console's startup log **before any browser**:
`SSO self-registered OIDC client "risingwave-console" … (redirect_uri …op-qa…/auth/sso/callback)`.
Then a human signs in at `https://risingwave-console.op-qa.usxpress.io/`. A 200 on
`/dex/auth` proves nothing — it answered 200 throughout dev's broken window.

**5.** `virtualservice-dashboard.yaml` on branch `op-qa`:
`risingwave-console.risingwave.svc.cluster.local:8020` →
`risingwave-meta.risingwave.svc.cluster.local:5691`. Copy the destination from that branch's
`virtualservice-overview.yaml`, which already serves the meta dashboard.

**6.** Pass: `risingwave-dashboard.op-qa` → `cc738d9a03a28c9a`, console still
`9980ad26c2748234`, human signs in again.

## Prod — same six steps, after QA

Prod's own platform node IPs must come from **prod's** `virtualservice-dashboard.yaml`
(10 workers, not QA's 3). Branch `op-prod`, base `--base op-prod`.

**Prod has real users on these URLs**, no Alertmanager delivery, and
`iaac-risingwave-onprem` has no promotion gate. QA2 → dev → QA → prod
([[promotion-order-qa2-dev-qa-prod]]); do not start prod until QA step 6 is green.

## Entra app registration `e112d6ce-cc60-4884-9898-8fcc5b78b0b1`

One registration for all three environments; only the redirect URI differs. The list grows
to **6** before the old three come out:

| | |
|---|---|
| started | 3 — `risingwave-dashboard.op-{dev,qa,prod}/dex/callback` |
| now | **5** — plus `risingwave-console.op-{dev,qa}/dex/callback` |
| after prod | 6 |
| after cleanup | 3 — console only |

**Add, never replace.** `az ad app update --web-redirect-uris` overwrites the list, so the
update passes the full existing set plus one and the gate is `AFTER == BEFORE + 1`. A short
list takes a login away from another environment.

## Proven

* Dev: dashboard → meta dashboard, console → console with SSO, human login 16:38 UTC.
* QA: `risingwave-console.op-qa.usxpress.io` serves the console (`9980ad26c2748234`,
  `verify=0`), record in Route 53 at `10.10.82.106,10.10.82.139,10.10.82.23`.
* A new hostname needs **one object**. A 404 with `ssl_verify_result=0` proves the wildcard
  covers it, measurable before the work.
* Entra at 5 URIs, every original intact, verified by read-back.

## Tested and killed

* "QA and prod were fixed too." No — the dev change was scope-gated to
  `manifests/op-usxpress-dev/` by design.
* "A working endpoint means the Kustomization applied." QA serves the new route with
  `Ready=False` and a two-commit-stale revision.
* "`qa/...` is a fine branch name." It cannot be pushed in that repo.

## Traps

1. **Never resolve one of these hostnames before its record exists** — 86400s negative TTL.
   `risingwave-console.op-prod.usxpress.io` has **not** been queried; keep it that way. Every
   check so far used `curl --resolve` or the Route 53 API
   ([[ask-the-registry-not-the-resolver]]).
2. **`risingwave-routes/kustomization.yaml` enumerates.** A new file not listed applies to
   nothing, silently.
3. **Targets are per cluster** — dev 7 workers, QA 3 platform nodes, prod 10 workers. A
   borrowed list is skipped by external-dns with no error.
