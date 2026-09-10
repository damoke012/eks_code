---
name: kustomization-enumerates-resources
description: A file added to a Flux-managed directory is only applied if that directory's kustomization.yaml lists it — some on-prem directories enumerate and others do not; and the entry must match the list's INDENTATION or the whole file becomes invalid YAML
metadata:
  type: project
---

In `iaac-talos-flux-platform`, whether a new file reconciles depends on the directory:

| Directory | `kustomization.yaml` | Adding a file |
|---|---|---|
| `infrastructure/istio-ingress/` | **absent** | Flux generates one; the file applies |
| `infrastructure/velero/` | **enumerates resources** | must be added to the list |
| `infrastructure/risingwave-routes/` | **enumerates resources** | must be added to the list |

On 2026-08-31 the RisingWave metastore Velero Schedule was written into
`infrastructure/velero/` and would have sat in git unapplied — the Kustomization would have
reconciled green, and the backup the on-prem metastore depends on would never have run. The
file's own comment warns about a different silent failure and would not have caught this one.

**Why:** "the file is on the branch" is not "the file is applied", and the two directories
behave differently in the same repo, so neither habit is safe.

**How to apply:** after adding any file to a Flux-managed directory, run
`kubectl kustomize <dir>` and grep the output for the resource you just added. Absence from
that output is the whole finding. Related: [[manifests-copied-across-branches]],
[[flux-stale-dependency-cascade]], [[adjacent-step-green-signals]].

**2026-09-08 — enumerating it is not enough; the entry has to be valid YAML.**
`scripts/pr-tim-rbac-op-dev.sh` appended `- rolebinding-….yaml` at **column 0** beneath a
`resources:` list indented two spaces. Every existing entry was at indent 2. That is not a
cosmetic difference: a block sequence cannot change indentation partway through, so the
file stopped parsing entirely. The PR would have taken `infrastructure/rbac` **down** —
including the three platform tiers already in it — rather than adding one binding.

`infrastructure/rbac/` on `op-dev` holds `clusterrole-onprem-platform-reader.yaml`,
`clusterrole-onprem-platform-operator.yaml` and `clusterrolebindings-groups.yaml`. So the
group-keyed tiers **are** on the dev branch, and a cert carrying
`O=onprem-platform-users` really would pick up cluster-wide read — worth knowing before
choosing a subject's `O=` for a namespace-scoped grant.

**Two checks that would have caught it, one of which existed and was ignored:**

1. **`grep -qF "$name" kustomization.yaml` passes on a file no parser will accept.** The
   assertion has to `yaml.safe_load` the file and find the entry *in the `resources`
   list*. Grepping the text you just wrote confirms the write, not the result — see
   [[proxy-is-not-the-property]].
2. **`kubectl kustomize <dir>` DID refuse to build**, and the script printed
   *"could not build — check it by hand"* and carried on to commit. A real failure signal
   downgraded to a note, inside the guard written to catch exactly this. If a check is
   worth running, its failure is worth stopping on — see [[adjacent-step-green-signals]].

**How to apply.** When appending to a YAML list: read the indentation off the existing
items rather than hardcoding one, then parse the file back and assert on the parsed
structure. And never let a build/render step report failure without exiting non-zero.
