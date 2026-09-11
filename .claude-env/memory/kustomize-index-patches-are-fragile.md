---
name: kustomize-index-patches-are-fragile
description: JSON6902 patches addressing a list by index break or silently retarget when the base list changes length; render the overlay to see it
metadata:
  type: project
---

**An overlay patch that addresses `/spec/data/3/...` is coupled to the LENGTH of a list
that a different file owns.**

`risingwave-pipeline`'s QA and prod overlays each carry five `op: replace` patches
against the base ExternalSecret's `data` list, one per index. On 2026-09-10 the base
dropped two entries (`POSTGRES_ENTITY_USER` / `_PASSWORD`) and the overlay still patched
indexes 3 and 4:

    $ kubectl kustomize deploy/overlays/qa
    error: replace operation does not apply: doc is missing path: /spec/data/3/remoteRef/key: missing value

Argo reports a sync error and applies nothing — so a PR that fixes a wedge can leave the
environment just as wedged, with every check green on the PR.

**The louder half is the lucky half.** Had the base dropped an entry from the MIDDLE
instead of the end, every index after it would still resolve and land on the wrong
entry — `PG_USER`'s `remoteRef` repointed at `entity-postgres`, breaking a credential
that works today, with no error anywhere.

**Why:** the diff shows the base change and the overlay separately, and each looks
correct on its own. The coupling exists only in the rendered output.

**How to apply:** after any change to a base list that overlays patch, run
`kubectl kustomize <overlay>` for **every** overlay, not just the one in the PR — prod's
copy carried the identical pair. Prefer patching by value (target the entry whose
`secretKey` is X) over by position. Same family as
[[kustomization-enumerates-resources]] and [[manifests-copied-across-branches]].
