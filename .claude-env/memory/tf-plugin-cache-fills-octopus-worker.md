---
name: tf-plugin-cache-fills-octopus-worker
description: "DX-Apply fails with 'no space left on device' because the Terraform plugin cache is keyed per app AND per module; 12 apps held 35GB of a 40GB volume on octopusworker-1 (qa-one), and the usxpress-qa pool also runs iaac-talos."
metadata:
  type: project
---

**2026-09-30, `octopusworker-1`, namespace `octopus`, cluster `qa-one`** (cloud QA EKS,
account 527101283767). `netradyne-coaching-session-sync` failed DX-Apply to qa. The worker's
`/cache` was at **39 G of 40 G**.

```
/cache/USXpress/<app>/tf_plugin_cache/<group>/<module>
                                      ^^^^^^^^^^^^^^^^ per app AND per module
```

Each of ~15 modules keeps its own copy of `hashicorp/aws` and friends, so **one app reaches
2.8 GB**. Twelve apps held **35 of the 39 GB**; removing only `*/tf_plugin_cache` recovered
the volume to **3.8 G / 10%**. An app directory holds only `bin` and `tf_plugin_cache`.

> **40 GB ÷ 2.8 GB ≈ 14 apps per worker.** QA has more than fourteen, so which worker fails
> is decided by which apps landed on it. Worker-0 sat at 17 G — six apps in — at the same
> moment worker-1 was wedged.

**Why:** a plugin cache exists so one provider copy serves every module. Keyed per module it
is not protecting the disk, it is consuming it. Set in `mage-runner`,
`internal/terraform.(*tfExec).init`.

**How to apply:**
```
kubectl --context qa-one -n octopus exec octopusworker-1 -- df -h /cache
kubectl --context qa-one -n octopus exec octopusworker-1 -- \
  sh -c 'rm -rf /cache/USXpress/*/tf_plugin_cache && df -h /cache'
```
Check no deploy is running on that worker first. First run per app afterwards is slow.

⚠️ **The error inverts cause and effect.** It prints `The specified plugin cache dir …
cannot be opened: no such file or directory` FIRST under "problems with the CLI
configuration", which sends you to check the path. The directory is absent *because it could
not be created*; `no space left on device` is four lines lower. Related:
[[adjacent-step-green-signals]].

⚠️ **A pod restart is not the fix.** `/cache` is an RWO PVC — remounted, not recreated.

⚠️ **Not a DX-only problem.** The `usxpress-qa` pool (`WorkerPools-1522`) also runs
**`iaac-talos`** — QA2's plan ran on `octopusworker-0` on 2026-09-17. A full cache fails
on-prem cluster builds too and presents as an unrelated Terraform init failure.

⚠️ **It recurs.** The `cache-octopusworker-*` PVCs were **24 h old** against **336 d**
`metadir` PVCs — cleared the previous day, refilled 39 GB within a day. Nothing alerts on
volume utilisation in that namespace; a `kubelet_volume_stats_available_bytes` rule at 80%
would have paged days earlier.

⚠️ `[Replicator] Completed Apply` ran before the failure, so a failed DX deploy is
**partially applied** — see [[dx-deploy-failure-not-clean-release]]. A retry is not a clean
slate.

Resizing to 100 Gi buys ~35 apps and moves the ceiling without removing it. The fix is one
shared `TF_PLUGIN_CACHE_DIR`. Full record:
`wip/dx-worker-capacity/FINDINGS-2026-09-30-tf-plugin-cache-fills-the-worker.md`.

**✅ Resolved 2026-09-30.** Clearing the caches took worker-1 from 39 G/98% to **3.8 G/10%**;
the redeploy completed in 2 minutes with `[Replicator]`, `[Mongodb-User]` and `[Cron]` all
applying. Verified in the output rather than the tick: `[Cron]` reported `Schedule:
*/30 * * * *` and `Suspend: false`. Worker-0 left at 17 G deliberately — not blocking, and
wiping it would only slow the next deploys.

**Now a skill:** `.claude/skills/dx-apply-triage/SKILL.md` (model-invoked), so the next
DX-Apply failure starts at the worker's disk and reads the error stack from the bottom.
