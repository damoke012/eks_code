---
name: gitops-has-four-stale-layers
description: "Between a merged PR and a running process there are four caches — GitRepository, Kustomization, HelmRelease, Pod — and each reports Ready while the next is still serving the old thing; verify at the process, not at any layer above it"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 47b0e9a0-2e5c-4874-83f1-06d3268ab121
  modified: 2026-09-03T20:55:10.988Z
---

**2026-09-03, op-prod Grafana.** A merged PR took four separate pushes to reach the process,
and at every stopping point something authoritative said everything was fine.

| layer | what it said | what was true |
|---|---|---|
| GitHub | `op-prod` HEAD = `2511e0e` | ✅ |
| GitRepository `infra` | serving `3fe256fc` | **one commit behind** |
| Kustomization `grafana` | `Ready=True`, applied `3fe256fc` | applied an **old** commit, truthfully |
| ConfigMap (Helm *values*) | updated to `op-prod` after reconcile | HelmRelease had not re-rendered |
| Pod | `3/3 Running`, **age 9d** | running `grafana.ini` from nine days ago |

`scripts/flux-revision-drift.sh` reported **"OK: all 41 Kustomizations are at the revision
their source is serving"** throughout. That statement was *true and useless*: it compares
**applied vs serving**, and when the source is stale both are the same old commit. Nothing in
the repo compared either against the branch HEAD.

**How to apply.**

1. **`lastAppliedRevision` is not "your change is live"** — read the sha and compare it to
   `gh api repos/<org>/<repo>/commits/<branch> --jq .sha`.
2. **A Kustomization applying a ConfigMap of Helm *values* does not re-render the release.**
   The HelmRelease needs its own reconcile before the chart regenerates its config and the
   deployment rolls. `flux reconcile helmrelease <name> -n <ns>`.
3. **Finish at the workload.** Compare the pod's `.status.startTime` against when the config
   changed. A correct value in a ConfigMap or Secret is not the value the process is running
   — the same trap as [[pod-env-secret-resolution]] and the RisingWave console licence, which
   also bit today.
4. When impatient, the sequence that actually pushes it through:
   `flux reconcile source git <src>` → `flux reconcile kustomization <k> --with-source` →
   `flux reconcile helmrelease <hr> -n <ns>`.

**Two probes that told me nothing and were nearly read as findings:**
`curl /api/frontend/settings | .appUrl` returned `None` — the endpoint is **401**, so that was
an auth failure, not a wrong value ([[transport-failure-not-a-verdict]]). And
`curl -sI /login | grep -i location` returning nothing is not evidence either way: `/login`
answers 200 with no redirect whatever `root_url` says. **A check that cannot fail is not a
check.**

Related: [[adjacent-step-green-signals]], [[octopus-green-but-no-apply]],
[[flux-stale-dependency-cascade]], [[proxy-is-not-the-property]].

## 2026-10-08 — ⛔ THE INSTANCE BELOW WAS WRONG. A reconcile in flight reads as a stuck one.

**Corrected the same evening.** `risingwave-routes` on op-qa was re-read and showed
`Ready=True`, `Applied revision: op-qa@sha1:b2b6cb37` — the merge commit —
`lastTransitionTime: 2026-10-08T17:48:01Z`. The earlier reading caught it **mid-reconcile**,
and I called it blocked, wrote it into two documents and stopped a rollout on it.

**The discriminator is time, and my probe did not capture it.** A Kustomization's condition
is one sample of a loop that runs every few minutes. `Ready=False` with a stale
`lastAppliedRevision` is what a reconcile *in progress* looks like **and** what a wedged one
looks like. Print `lastTransitionTime` and the `reason`, and read it twice, before calling
either. A single sample is not a state — [[proxy-is-not-the-property]].

The mechanism described below is real and worth keeping; **the instance was not**.

## The mechanism — a PARTIAL apply keeps the OLD revision, and the objects stay

Fifth layer. What `kustomization/risingwave-routes` on op-usxpress-qa appeared to show — and
which turned out to be a reconcile in flight, see the correction above:

    READY=False   APPLIED=op-qa@sha1:7acb311e

while the branch head was `b2b6cb37` and the previous head `fca6d26` — so it had not
completed an apply for **at least two commits**. Yet the VirtualService added by the newer
commit **was live and serving** (`risingwave-console.op-qa.usxpress.io` → 200, correct body
hash).

**Flux sets `lastAppliedRevision` only on a fully successful apply.** When some objects apply
and one fails, the applied objects stay, the Kustomization goes `Ready=False`, and the
revision stays pinned to the last complete run. So:

* **A working endpoint does not mean the Kustomization applied.** Half of it may have.
* **A stale `lastAppliedRevision` does not mean nothing changed.** Objects from newer commits
  may already be live, unmanaged and un-pruned.
* Drift between *applied* and *serving* reads clean, because both are the same old commit —
  exactly the blind spot in `scripts/flux-revision-drift.sh` described above.

**How to apply:** read `READY`, `lastAppliedRevision`, the condition `reason`, the `message`
**and `lastTransitionTime`** — then read it again a minute later. A `Ready=False` that is
seconds old is a reconcile running; one that is hours old is wedged. Only the second is a
reason to stop — the next change to that directory will merge, report green in GitHub, and
never land. There is no Alertmanager delivery on-prem to say otherwise
([[onprem-alerts-not-delivered]]).

Same family as [[server-side-apply-keeps-dropped-fields]], where one rejected field froze a
whole Kustomization for 4h with every other signal green.

## 2026-10-08 — the ANNOTATION form of `--with-source` is two annotations, not one

Flipping dev's ETL Application to Helm (platform #173). After the merge I forced a reconcile
with:

    kubectl -n flux-system annotate kustomization argocd-apps \
      reconcile.fluxcd.io/requestedAt=<now> --overwrite

and read back:

    argocd-apps ready=True  applied=op-dev@sha1:03c6e830      <-- the PRE-MERGE sha
    Application  path=deploy/overlays/dev  helm=null

**Annotating the Kustomization re-applies whatever the GitRepository is already serving.** It
does not fetch. `Ready=True` was truthful: it had successfully applied an old commit. The
merge commit `797a56c5` was sitting in GitHub, unfetched.

`flux` is **not installed on the WSL box**, so `flux reconcile kustomization --with-source` is
unavailable and the annotation path is what we actually use. The equivalent is **two**
annotations in order, with a check between them:

    kubectl -n flux-system annotate gitrepository infra  reconcile.fluxcd.io/requestedAt=<now> --overwrite
    # then assert .status.artifact.revision contains the branch HEAD from `gh api`
    kubectl -n flux-system annotate kustomization argocd-apps reconcile.fluxcd.io/requestedAt=<now> --overwrite
    # then assert .status.lastAppliedRevision is that same sha

**How to apply.** Before reading any Kustomization's result, assert its SOURCE is current
against `gh api repos/<org>/<repo>/commits/<branch> --jq .sha`. A reconcile that returns
quickly with `Ready=True` and an unchanged `lastAppliedRevision` is the signature — and it is
indistinguishable from a successful no-op change, which is exactly what I had expected to see.

This note already said "lastAppliedRevision is not your change is live" and "flux reconcile
kustomization --with-source". I read the note and still annotated the wrong object, because
the no-CLI workaround was not written down. **A procedure that exists only as a CLI flag does
not survive the absence of the CLI.**

Once the source was fetched, all four layers went current and **every object kept its
resourceVersion** — the strongest available confirmation that the Helm render was identical
to the Kustomize render.
