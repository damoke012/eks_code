# INFRA-1661 — where it stands, 2026-10-27 00:15

**One click from done.** `0.5.0` → Deploy to Production, once QA reports Success.

## Right now

| | |
|---|---|
| QA deploy of `0.5.0` | **Executing**, started 2026-10-26T23:45:34 |
| Production | still on `0.1.3-fix-drop-duplicate-risingwave-irsa.1.2` (2026-09-14) |
| Next action | wait for QA `Success`, then deploy `0.5.0` to Production |

```bash
python3 scripts/octopus-project-state.py 2>&1 | sed -n '/deployed now/,/latest/p'
```

## Proven before stopping

* **Webhook kubeconfig on all three prod control-plane nodes** — 1909 bytes each, the same
  size as QA's. `scripts/check-authenticator-webhook-file.sh prod`.
* **QA's cluster already carries the change** — both apiserver flags present and
  `auth whoami` returns `sso:doke@usxpress.com` in `onprem-platform-admins` after the deploy.
* **`0.5.0` carries the module code** — `8c732fce` merged 2026-09-14T16:28Z, that file
  untouched since, release assembled three days later.
* **The release snapshot carries the flag** scoped to `production` —
  `scripts/octopus-project-state.py --release 0.5.0`.
* **`TF_USE_VARFILE` is unset for production** (only `qa2 = 'false'`), so `TF_VAR_*` rules.
* **Break-glass works** via the `ops-controller` profile.
* **The Octopus project is enabled again** — it had been disabled since 2026-10-22.

## When deploying prod

1. Break-glass terminal open and visible:
   `watch -n5 kubectl --kubeconfig=$HOME/.kube/op-usxpress-prod-breakglass.yaml get nodes`
2. Expect a **20-minute pause** at `[HEALTH] Waiting for istiod`. It is a known defect and
   does not fail the deploy — [[istiod-health-wait-cannot-fail]].
3. Three control planes roll one at a time. Stop if a node is NotReady for over ~2 minutes.
4. Verify: two `authentication-token-webhook` lines on the apiserver, then `auth whoami`
   through an SSO kubeconfig returning an `sso:` identity.

## Open afterwards

* **Re-run `scripts/octopus-enable-project.py` read-only in a day.** Something set
  `IsDisabled` on 2026-10-22 at 13:00:29 as `lazy`, from a CI runner, using an API key
  created 2021-01-26. If it comes back disabled, that automation is still running.
* **That API key is its own finding** — five and a half years old, and it can stop delivery
  to all three clusters.
* **The istiod wait discards both error streams**, so unreachable and not-ready are the same
  empty string. One-line fix, and it would save 20 minutes on every op-qa and op-prod deploy.
* **INFRA-1663 needs re-reading.** "No Talos machine config in iaac-talos" does not match
  what was measured: the module is environment-generic and production carries 29 `TF_VAR_*`,
  the same as QA. It may describe the design rather than a gap.
* **Was tonight's variable add necessary?** The `0.5.0` snapshot carries the production scope,
  but whether that came from the Update Variables click or was always there is unresolved. It
  decides what INFRA-1661's real cause was.

## Not blocking, but found tonight

* etcd snapshots proven on all three clusters, 31-day window — **restore never tested**.
* Office access to prod was already fixed; the plan said it was outstanding.
* No permission set named `op-prod-platform-admin` exists.
