# Message to Idris — 2026-09-08 — your two open PRs

Idris — caught up on the PR queue. The two promotions are dealt with, so what is
left is yours.

**Promotions, for context:** #17 closed as superseded (`310aa151` is an ancestor of
`4873de43`, checked with `merge-base --is-ancestor` rather than by date), #20 approved
and merged. QA had been sitting on the 19 August image for three weeks. It now carries
your INFRA-1675 work — the guardrail regex, the `apply.sh` routing, the per-env account
IDs, and the per-environment `risingwave` namespace mapping. That was the change I had
asked for on #19; thank you for turning it round.

---

## #21 — "harden pipeline apply routing and configuration"

It has grown since I read it. My Round 1 was against `7fd05d73`, **+90/-32 across 5
files**. It is now **+779/-34 across 7 files**. So I am not going to pretend my earlier
comments still describe it — tell me what changed and I will re-read the whole diff.

What I asked for still stands, and the first one is the reason it is not merged:

1. **Split the two overlay files into their own PR, QA only.** `PIPELINE_DIR` moving
   from `/pipeline/smoke` to `/pipeline/pipelines` is the go-live. I am not approving
   that inside a PR about hardening a script, and not on QA and prod at once.
2. **In that cutover PR, list every directory under `pipelines/`** and mark each in or
   out with a reason. Three we agreed on 26 August are still not in the exclude list:
   `900-user-access`, `001-secrets-mongodb`, `400-sink`.
3. **Two fixes in `apply.sh`:** hash the *rendered* SQL rather than the template —
   otherwise changing a variable's value is skipped and the Job still reports success —
   and fail rather than `exit 0` when `EXCLUDE_RE` matches everything.
4. **Write down what happens after a bad apply.** There is no way back today. This is
   the one blocker from the architecture review that is still not acknowledged anywhere,
   in the diff or the follow-up list.

To be clear about the rest: the hardening is good. Moving the `pipeline_applied` table
creation to after the missing-variable check is exactly right — nothing opens a
connection until validation passes — and replacing the `:?` fail-fast with collected
validation reports every missing variable at once instead of dying on the first. That is
a better failure. `EXCLUDE_RE` with a stable root is also the better design, and it is
the option the architecture review argued for. I will merge that half the day it is on
its own.

## #18 — "replace hardcoded AWS account ID in OIDC workflows"

**#19 has overtaken this one.** It removed the `secrets.AWS_ACCOUNT_ID` usage that #18
introduces, so the workflow half of #18 — the part the title is about, and the part that
was correct — is now redundant.

What remains is **112 files and +60,103 lines**: PowerShell connection helpers, template
automation, credential guidance, docs. Under a title about one ARN. Nobody can review
that honestly, and I am not going to approve it by skimming.

Please either close it, or split the tooling and docs into their own PR with a title
that says what they are. If there is anything left in the workflow half that #19 did not
cover, that is a third, tiny PR and I will take it today.

---

Nothing else is waiting on you. Ping me when the QA cutover PR is up and I will turn it
round same day.

— Dare
