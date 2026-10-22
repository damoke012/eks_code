---
name: merged-defect-authorizes-itself
description: a check that compares new work against "what's already there" is disarmed the moment a bad change merges
metadata:
  type: feedback
---

A check whose baseline is "what the repo already does" **gets weaker exactly when it is
needed most**: once a defect merges, it becomes its own precedent and the check passes it.

2026-08-25: a new ExternalSecret was written as `external-secrets.io/v1beta1` while op-qa
serves `v1`. Flux rejected it at dry-run, freezing the `argocd`, `argocd-config` and
`argocd-apps` Kustomizations. A linter written to catch exactly this went **green** when
self-tested against the real defect — twice over:

1. the bad file was by then merged to `op-qa`, so the baseline contained it and it
   authorised itself;
2. "this apiVersion appears somewhere on the branch" counted as agreement, when the true
   split was **11 × v1 and 1 × v1beta1 — the one being the bug**.

**Why:** precedent-based checks silently invert into defect-propagation once the defect is
in the corpus. Majority is not the same as presence, and "the branch" is not one voice.

**How to apply:** exclude the files under test from the baseline; pin the baseline to a ref
*before* the change (`--base`); compare against the **dominant** value and print the
distribution, never mere presence. And **always self-test a new check against the real
defect, in both directions** — red on the bug, green on the fix. `scripts/lint-manifest-apiversions.py`
does all four; it is gated into `scripts/pr-argocd-entra-qa-prod.sh` before push.

Fourth instance in one day of a check failing in a way indistinguishable from a finding —
see [[adjacent-step-green-signals]], and [[argocd-onprem-entra-oidc]] for the others.


**Third check written so it could not fail, 2026-08-25.** `pr-argocd-rbac-app-viewer.sh`
asserted "op-prod must not grant sync" by substring-testing text that the no-sync branch never
writes — it passed on every input, including a deliberate violation. Rewritten to *count the
matching grant lines*, it went red immediately. The tell: an assertion whose subject is a
string **you** just chose whether to write. Assert over the parsed result, not over your own
output.
