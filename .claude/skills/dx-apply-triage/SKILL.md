---
name: dx-apply-triage
description: Triage a failed DX-Apply Octopus deployment — "The remote script failed with exit code 1" on a DX-Apply step, "no space left on device", OpenTofu "Failed to install provider", "plugin cache dir cannot be opened", a deploy that failed partway through its modules, a plan that fails READING a resource after a provider release (`ListVersionsByFunction`), or an app that deployed green and then broke on identity. Read the error stack from the bottom, and check the worker before the app.
---

# /dx-apply-triage

Triage a failed **DX-Apply** deployment in Octopus. The cause is usually the *worker* rather
than the app, and the log's first error is usually the consequence rather than the cause.

Built from the 2026-09-30 `netradyne-coaching-session-sync` failure to qa — the app held the
smallest cache on the worker and failed because it deployed last.

## When to use

- A DX-Apply step ends `The remote script failed with exit code 1`.
- `no space left on device`, `Failed to install provider`, or `plugin cache dir … cannot be
  opened` anywhere in the log.
- A deploy failed after some modules already reported `Completed Apply`.
- A plan or refresh fails **reading** an existing resource, naming an AWS API nothing in the
  code calls — the provider was resolved fresh that day.
- An app deployed green and then broke on authentication.

## Rule zero — read the error stack from the bottom

OpenTofu prints configuration complaints **before** the fatal error, so the first thing you
read sends you to the wrong place.

```
error running Init: exit status 1
There are some problems with the CLI configuration:            <- reads as misconfiguration
Error: The specified plugin cache dir … cannot be opened:
       no such file or directory                               <- the CONSEQUENCE
As a result of the above problems, OpenTofu may not behave as intended.
Error: Failed to install provider
Error while installing hashicorp/aws v6.66.0: write …:
       no space left on device                                 <- the CAUSE
```

The directory is absent *because it could not be created*. **Start at the last error and work
up.** A retry after ten seconds that fails identically confirms a persistent cause; a genuine
transient clears.

## Triage order

Work down. Each step is cheap and rules out a whole family.

### 1. The worker's disk

The most common cause, and invisible from the app's side. Identify the worker from line ~3,
`Releasing package lock for octopusworker-N.<env>.usxpress.io`.

```bash
kubectl --context qa-one -n octopus exec octopusworker-1 -- df -h /cache
kubectl --context qa-one -n octopus exec octopusworker-0 -- df -h /cache
```

Check **every worker in the pool**, not the one that failed: they fill in rotation depending
on which apps land where, so the healthy one is the next outage.

```bash
kubectl --context qa-one -n octopus exec octopusworker-1 -- \
  sh -c 'du -sh /cache/USXpress/* 2>/dev/null | sort -h | tail -20'
```

An app directory holds exactly two things, `bin` and `tf_plugin_cache`. Confirm that, then
clear only the caches — after checking Octopus → Tasks that nothing is mid-deploy on that
worker:

```bash
kubectl --context qa-one -n octopus exec octopusworker-1 -- \
  sh -c 'rm -rf /cache/USXpress/*/tf_plugin_cache && df -h /cache'
```

⛔ **Clear the cache in place.** `/cache` is an RWO PVC: deleting the pod remounts the same
full volume, costs an outage and changes nothing.

**Why it fills, and why clearing it is not a fix.** The cache path is

```
/cache/USXpress/<app>/tf_plugin_cache/<group>/<module>
                                      ^^^^^^^^^^^^^^^^ per app AND per module
```

A plugin cache exists so one provider copy serves every module. Keyed per module, each of
~15 modules stores its own `hashicorp/aws`, so **one app reaches 2.8 GB**. On a 40 GB volume
that is a **ceiling of about fourteen apps per worker** — measured 2026-09-30: twelve apps
held 35 of 39 GB, and removing the caches recovered the volume to 3.8 GB. Resizing moves the
ceiling; one shared `TF_PLUGIN_CACHE_DIR` removes it. Set in `mage-runner`,
`internal/terraform.(*tfExec).init`.

⚠️ **The same pool runs `iaac-talos`.** `WorkerPools-1522` (`usxpress-qa`) serves both DX apps
and our on-prem cluster builds — QA2's plan ran on `octopusworker-0`. A full cache fails a
Talos deploy too, and presents as an unrelated Terraform init failure.

### 2. What already applied

A DX-Apply runs its modules in sequence and each reports its own `Completed Apply`. A failure
partway leaves everything above it **applied**.

Read the log for `[<Module>] Completed Apply` before deciding a retry is a clean slate. In the
2026-09-30 failure, `[Replicator] Completed Apply` had already run when `mongodb-user` died at
`init`.

### 3. Identity, if the deploy was green and the app is broken

Every DX deploy **destroys and recreates** the app registration, so the client ID changes.
Anything holding the old ID — especially an on-prem copy of the same app — breaks on a *cloud*
release, with nothing in either log connecting the two. Consumers need a full release, not a
config change. See `prod-auth-triage` for the 401 side of this.

### 4. A provider release you did not choose

A repository that gitignores `.terraform.lock.hcl` resolves the provider **at init**, so a run
takes whatever was published that morning. The failure then arrives at **read** time, with
nothing applied, naming an AWS API that appears nowhere in our code.

**Measured 2026-10-16, `ix-kafka-topics-users` dev.** `hashicorp/aws` 6.69.1, released that
day, made the read of `aws_lambda_function` issue an internal **`ListVersionsByFunction`**
call, which errored and blocked the deployment. Parul's own words: *"in our code we have just
written `resource aws_lambda_function`, but in the background the provider, using AWS APIs,
tries to call this `ListVersionsByFunction` call."* Octopus **publishes a new Lambda version on
every deploy**, so these functions carry long version lists — that is the state being walked.

```
# which version did THIS run resolve?  (raw log, not the rendered view)
grep -iE 'Installing hashicorp/aws|provider registry.*aws' <raw task log>
```

Read the **raw** log. The rendered Octopus view truncates the error — on the call it took
opening the raw log and searching `list versions` to see it at all.

The fix is a constraint (`< 6.69.1`) in the **shared** configuration, so one merge covers
every environment. ⚠️ **A pin is not a fix and has no expiry**: re-test each patch release and
revert deliberately, or the constraint is load-bearing a year later with nobody left who
knows why. Full account:
`wip/onprem-app-cicd/FINDINGS-2026-10-20-aws-provider-lambda-listversions.md`.

Two traps specific to this class:

* **Grepping our Terraform for the failing API finds nothing, and that is expected.** The
  call is inside the provider. An empty grep is not exculpatory.
* **"The Lambda version" and "the provider version" get used interchangeably in
  conversation.** What is frozen is the provider's; newer Lambda runtimes are unaffected.

### 5. Lines that look like failures and are not

| Line | Reading |
|---|---|
| `NoSuchKey: The specified key does not exist` followed by `Skipping <X> Module` | module not enabled, no state yet. Normal. |
| `No structures have been found that match variable names` | no substitution targets in that file. Normal. |
| `Key in file infrastructure.<x> false` | the spec does not request that module. Normal. |
| Two different OpenTofu versions in one log | modules pin independently. Normal. |

## What a green retry proves

It proves the modules applied. Confirm the thing that failed is now **absent from the log**,
and read the `Outputs:` blocks for the values the app will actually run with — a deploy can
complete having written config nobody checked.

For a cron app, `Suspend: false` and the schedule appear in the `[Cron]` output. That is the
statement that it will run; a successful deploy on its own is not.

## After the fix

Clearing a cache silently is how this reached its second occurrence with no ticket. The
`cache-octopusworker-*` PVCs were 24 hours old against 336-day `metadir` PVCs — cleared the
previous day, refilled 39 GB within a day.

Record it (`capture-learning`), and file the durable fix with the numbers as the argument:
twelve apps, 2.8 GB each, a 40 GB volume, a fourteen-app ceiling.

Full record: `wip/dx-worker-capacity/FINDINGS-2026-09-30-tf-plugin-cache-fills-the-worker.md`
