# The Terraform plugin cache is what fills the Octopus worker

**2026-09-30.** `netradyne-coaching-session-sync` failed DX-Apply to qa. Not the app's
fault: the worker's `/cache` volume was full.

Scope: **`octopusworker-1`, namespace `octopus`, cluster `qa-one`** (cloud QA EKS, account
527101283767), measured 2026-09-30 ~19:30 UTC. Worker-0 measured at the same time. Prod
workers **not** measured.

---

## What is proven

### 1. The disk was full, and the first error says something else

```
error running Init: exit status 1
There are some problems with the CLI configuration:
Error: The specified plugin cache dir /cache/USXpress/netradyne-coaching-session-sync/
       tf_plugin_cache/common/mongodb-user cannot be opened: no such file or directory
As a result of the above problems, OpenTofu may not behave as intended.
Error: Failed to install provider
Error while installing hashicorp/aws v6.66.0: write .../terraform-provider-aws:
       no space left on device
```

**Read top-down and you go and check the cache path configuration.** The directory is absent
*because it could not be created*. The cause is four lines lower. It retried after ten
seconds and failed identically — a transient would have cleared.

### 2. The cache is the fill mechanism

```
$ df -h /cache
octopusworker-1   39G / 40G   98%
octopusworker-0   17G / 40G   42%

$ du -sh /cache/USXpress/*        (12 apps, worker-1)
885M  netradyne-coaching-session-sync      2.8G  netradyne-dx-api
2.8G  customer-profile-ui                  2.8G  netradyne-geofence-sync
2.8G  edi-management-ui                    2.8G  netradyne-score-sync
2.8G  graphql-gateway                      3.7G  ingestor
2.8G  manhattan-dl-coldstart               3.7G  manhattan-optimization-ingestor
2.8G  netradyne-device-installation-sync   4.6G  manhattan-dl-pipeline
```

An app directory holds exactly two things — `bin` and `tf_plugin_cache`. Deleting only the
caches took the volume from **39 G to 3.8 G**: the plugin cache was **35 of the 39 GB**.

The path is the problem:

```
/cache/USXpress/<app>/tf_plugin_cache/<group>/<module>
                                      ^^^^^^^^^^^^^^^^  per app, AND per module
```

A plugin cache exists so that one copy of a provider serves every module. Split per app and
per module, each of ~15 modules stores its own copy of `hashicorp/aws` and friends — which
is how one app reaches 2.8 GB. **The cache is not protecting the disk, it is consuming it.**

Set in `mage-runner`: `internal/terraform.(*tfExec).init`.

### 3. It is a ceiling, not bad luck

> **40 GB ÷ 2.8 GB ≈ 14 apps per worker.**

QA has more than fourteen apps. Which worker fails is decided by which apps happened to land
on it. Worker-0 sat at 17 G — six apps into the same budget — while worker-1 was wedged.

### 4. It has happened before and was cleared, not fixed

```
cache-octopusworker-0     40Gi   gp3      24h    <- recreated yesterday
cache-octopusworker-1     40Gi   gp3      24h
metadir-octopusworker-0   100Mi  efs-sc   336d   <- the original volumes
metadir-octopusworker-1   100Mi  efs-sc   336d
```

The cache volumes are a day old; the metadir volumes are eleven months old. Someone
recreated the cache PVCs yesterday, and **worker-1 refilled 39 GB within 24 hours.**

---

## What we believed that was wrong

- **"A worker restart will clear it."** It will not. `/cache` is an RWO PVC that is
  remounted, not recreated. Deleting the pod costs an outage and changes nothing.
- **"This is that app's problem."** `netradyne-coaching-session-sync` held 885 MB, the
  smallest of the twelve. It failed because it deployed last.
- **"It is a DX problem."** The `usxpress-qa` worker pool (`WorkerPools-1522`) also runs
  **`iaac-talos`** — QA2's plan ran on `octopusworker-0` on 2026-09-17. A full cache fails
  our on-prem cluster builds too, and would present as a Terraform init failure with no
  obvious link to DX.

---

## Could a check have caught it

Yes, and nothing watches it. `/cache` is a PVC with no alert on utilisation, on a cluster
whose alerting does deliver (cloud), so this is a missing rule rather than a missing sink.
A `kubelet_volume_stats_available_bytes` rule at 80% on the `octopus` namespace would have
paged days before the deploy failed.

---

## Proven

- `octopusworker-1` `/cache` at 39 G of 40 G; DX-Apply failed on `no space left on device`
  while installing `hashicorp/aws v6.66.0`.
- 12 apps held 35 GB of Terraform plugin cache; the modal app is 2.8 GB.
- Removing only `*/tf_plugin_cache` recovered the volume to 3.8 G / 10%.
- The cache path is per app **and** per module, so every module keeps its own provider copy.
- The cache PVCs are 24 h old against 336 d metadir PVCs — this recurred and was cleared.

## Tested and killed

- **"Restart the pod."** RWO PVC, remounted full.
- **"The app directory holds build artefacts we need."** It holds `bin` and
  `tf_plugin_cache`, nothing else.
- **"The `NoSuchKey` on `common/kafka` is the failure."** It is followed by
  `Skipping KAFKA Module` — module not enabled, no state yet. Noise.

## Traps

- **The error order inverts cause and effect.** "Plugin cache dir cannot be opened" is
  printed first and reads as misconfiguration; "no space left on device" is the cause.
- **Clearing the cache is not a fix**, and doing it silently is how this got to its second
  occurrence without a ticket.
- **Resizing alone moves the ceiling**, it does not remove it: 100 Gi buys ~35 apps.
- `[Replicator] Completed Apply` ran before the failure — **a failed DX deploy is partially
  applied**, so a retry is not a clean slate.

---

## Resolved, same day

`rm -rf /cache/USXpress/*/tf_plugin_cache` on `octopusworker-1` took the volume from
**39 G / 98%** to **3.8 G / 10%**. The redeploy of
`netradyne-coaching-session-sync 0.0.7-f-DXT-2008-coaching-session.1.17` to qa completed in
**2 minutes** with every module applying in sequence — `[Replicator]`, `[Mongodb-User]`,
`[Cron]` — and Jira updated `successful`.

Confirmed in the output rather than from the green tick: `[Cron]` reported
`Schedule: */30 * * * *` and `Suspend: false`, which is the statement that it will actually
run. The `mongodb-user` module emitted its `user_id` and the config map
`netradyne-coaching-session-sync-m-u`.

Worker-0 was left alone deliberately at 17 G / 42% — it was not blocking anything, and wiping
it would have made the next several deploys slow for no gain. It is six apps into a
fourteen-app budget and is the next one to fill.

**Turned into a skill:** `.claude/skills/dx-apply-triage/SKILL.md`, so the next DX-Apply
failure starts at the worker's disk and reads the error stack from the bottom instead of
rediscovering both.
