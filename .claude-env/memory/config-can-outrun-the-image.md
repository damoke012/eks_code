---
name: config-can-outrun-the-image
description: A ConfigMap key the running image predates is silently ignored; check the feature exists in the deployed commit, not just in master
metadata:
  type: feedback
---

**A config key only does something if the code that reads it is in the image that is
running.**

2026-09-10, op-usxpress-qa: the QA overlay set `EXCLUDE_RE` to narrow a cutover to two
Brand files. The Job ran the image built from `4873de43`, which has no `EXCLUDE_RE`
handling at all — that arrived in the next commit, still unpromoted. The image ignored
the key, selected all 24 files, and only stopped because an unrelated guard noticed a
`.sql` file with no application database configured.

Two things to take from it:

**The tell was an absence.** `apply.sh` prints `exclude <path>` per skipped file. The
log printed none — that, not the error text, was the evidence. A missing line is easy to
read past.

**Verifying the config is not verifying the behaviour.** Two days earlier I ran that same
regex against the repo tree, confirmed 24 discovered / 22 excluded, and reported it as
verified. True about the regex, silent about whether anything in QA implements it.

**How to apply:** when an overlay introduces a new key, confirm the deployed commit reads
it — `gh api .../contents/<file>?ref=<the commit behind the digest> | grep <KEY>` — before
saying the setting takes effect. Same family as [[gitops-has-four-stale-layers]] and
[[proxy-is-not-the-property]]; config/binary skew is a fifth stale layer.
