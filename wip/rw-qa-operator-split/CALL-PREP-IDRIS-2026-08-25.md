# Call with Idris — 2026-08-25 13:00

**Direction in one line:** Idris owns what runs *inside* `risingwave`; platform owns the cluster,
ingress, secrets and delivery path underneath it. Everything below is sorted into those two lanes,
because most of the drift has come from the boundary being unstated.

---

## 1. Close the open item first (30 seconds, already acked)

He replied *"sure. you can run the fix"* — the meta pod recreation is approved and outstanding.

```bash
KC=$HOME/.kube/op-usxpress-qa-sso.yaml; CTX=op-usxpress-qa-sso
kubectl --kubeconfig=$KC --context $CTX -n risingwave delete pod risingwave-meta-default-0
```

Then meta Running 1/1 and hummock GC lines in the log. Do it with him watching, as offered.

**Why it still matters:** the fix inverted the exposure. The DB now holds the rotated password;
meta's pod env still holds the pre-rotation one, so today a *container* restart fails where a *pod*
recreation succeeds. Leaving it means it breaks unattended on the next node drain.

## 2. The one question only he can answer

**`risingwave-meta-default-0` restarted 238 times with exit 139 (SIGSEGV) in its first 16 hours,
then went stable.** We have no theory. Ask directly: known issue, version-specific, resource
shape? If he does not know either, it needs a ticket rather than a shrug — 238 segfaults that
resolved themselves is not a closed matter.

**What we can now answer on our side:** nothing alerted because there was no Alertmanager at all.
Dev had 40 rules and 54 alerts firing into a void; fixed on dev and QA 2026-08-24, prod still
pending. So "nothing alerted" was our gap, not his. Say that plainly.

## 3. What changed on our side since we last spoke

* **Prod cluster access is recovered** (INFRA-1663). It was the blocker on checking prod for the
  same postgres fault. `scripts/onprem-prod-kubeconfig.sh ops-controller` rebuilds a kubeconfig
  from `op-usxpress-prod/talosconfig`. So the prod check is no longer "opportunistic" — it can be
  run today.
* **Prod ingress has never worked.** Its shared Gateway serves `*.op-qa.usxpress.io`, its wildcard
  Certificate has been failing for 27 days, and cert-manager had no IRSA credentials. Being fixed
  now. Relevant to him because **all four `risingwave-routes` VirtualServices on the prod branch
  carry `op-dev` hostnames** — if RW ever goes to prod, those are wrong today.
* **Argo CD SSO via Entra** is live on dev and QA. Authentication works; group-based RBAC does not
  yet (Entra emits no groups claim). If he wants Argo access, that is the constraint.
* **App delivery into `app-risingwave` is proven end to end on QA.** Dev is not extended yet and
  prod has no Git credential.

## 4. Decisions to get from him

1. **Does RisingWave go to prod at all?** It was deliberately omitted from the prod stand-up. The
   prod branch nonetheless carries RW routes and certificates — copied, wrong, and currently inert.
   Either they get fixed as part of a real plan, or they should be removed rather than left to be
   discovered later as though they were intended.
2. **Who runs the postgres check on dev, and when?** `scripts/check-postgres-secret-usable.sh`
   compares initdb time against the secret's LastChangedDate and then actually authenticates.
   If dev is affected too, it is a pattern rather than an accident.
3. **The rotation procedure itself.** `POSTGRES_PASSWORD` applies only at initialisation, so any
   future rotation needs an explicit `ALTER USER` step. That belongs in whoever's runbook rotates
   these — his or ours. Decide which.
4. **INFRA-1645** — the QA RW routes that carried dev hostnames. Confirm it is actually closed.

## 5. He asked to see how the AI work is done

He asked; it is worth showing rather than describing. The honest demo is not "it writes YAML" —
it is the working discipline:

* every change built **from the branch**, never from a local draft;
* checks that assert against the **re-parsed result**, not the edit;
* the failure mode we keep hitting — **a check that breaks in a way indistinguishable from what it
  checks for** (five instances today alone); and
* findings captured immediately, with wrong beliefs corrected in place rather than deleted.

Today is a good live example end to end: chasing Argo SSO surfaced a production ingress that had
never issued a certificate. Show that trail.

## 6. Logistics

He is out on the **14th, 21st and 24th**. Anything needing his ack should be raised before the
14th or explicitly deferred.
