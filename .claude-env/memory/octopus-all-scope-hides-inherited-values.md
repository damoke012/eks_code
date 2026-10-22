---
name: octopus-all-scope-hides-inherited-values
description: "A generator that copies environment-scoped Octopus variables silently leaves every INHERITED value at the [ALL] default; QA2's first plan wanted 13 VMs because control_plane_count is [ALL]=3 and nothing scopes it."
metadata:
  type: project
---

**2026-09-17, Octopus project `iaac-talos` (`Projects-8283`, space `Spaces-2`).** QA2's first
plan came back `97 to add` — 3 control planes and 10 workers — for a cluster specified as 1 + 1.

Two different causes, only one of them visible:

- **`TF_VAR_control_plane_count` is `[ALL] = 3` and NO environment scopes it** — not dev, not qa,
  not production. `scripts/octopus-create-qa2-vars.py` derives a new environment from what the
  source environment scopes *explicitly*, so anything the source merely inherits is never read,
  never copied and never flagged.
- **`TF_VAR_worker_pools` was copied faithfully** — QA's value is
  `system 2 + platform 3 + application 5 = 10`. The copy was right; the intent was not.
  Byte-identical to QA's except `memory_mb`, where production differs (12288 vs 8192).

**Why:** the generator's contract is "copy what is scoped", and the set of scoped variables is
not the set of variables that matter. For a throwaway this oversizes. For a real environment it
under-sizes: `[ALL]` holds `cp_cpus=2`, `cp_memory_mb=8192`, `disk_size_gb=50`,
`worker_count=2` — dev-sized, wrong for production, and nothing says so. Same family as
[[adjacent-step-green-signals]].

**How to apply:** after generating an environment, list every `TF_VAR_*` it resolves through
`[ALL]` and confirm each deliberately. `scripts/octopus-set-env-var.py --env <env> --create
--set NAME=VALUE` creates the missing override and prints the inherited value it displaces;
without `--create` it correctly refuses to guess. `scripts/octopus-dump-talos-vars.py --full`
is required to read a complex value — the default 58-char truncation hid that `worker_pools`
defines three pools.

⚠️ Then refresh the release's variable snapshot — see [[octopus-release-freezes-variables]] —
or the next plan is identical and reads like a change that did not work.

⚠️ **Do not collapse a multi-pool cluster to one flat pool.** Platform manifests copied from
`op-qa` carry `pool=platform` / `pool=application` nodeSelectors and tolerations; a system-only
cluster strands them Pending with no error. Keep the pools, set each `count` to 1.
Related: [[manifests-copied-across-branches]], [[one-account-one-cluster-assumption]].
