---
name: transport-failure-not-a-verdict
description: A probe must never report a connection/exec failure as a finding about the system under test — use exit codes, and abort the run rather than emit verdicts
metadata:
  type: feedback
---

On 2026-08-28 a capability probe reported **eight statements as `UNSUPPORTED`** by
RisingWave. Every one was the same `kubectl exec` failure: `psql` is not in the
`risingwavelabs/risingwave:v2.8.2` image. The probe merged stderr and grepped for the word
`ERROR`, so a transport failure rendered as a verdict about the database.

**Why:** a red result about the wrong thing is as misleading as a green one — the inverse of
[[adjacent-step-green-signals]] and [[eso-secretsynced-not-content-check]]. It cost a full
round trip and would have produced a wrong architectural conclusion had it not looked
suspicious (all eight identical, and the version query silently empty).

**How to apply:**
* Discriminate by **exit code**, never by matching text: psql `0` ok, `2` cannot connect
  (ABORT the whole run), `3` SQL error (a real refusal), `124` under `timeout` (hung).
* **Preflight**: assert a known-good result (`SELECT 1` returns exactly `1`) and abort with
  the raw stderr if not. Never print verdicts after a failed preflight.
* Keep value queries stdout-only; diagnostics go to a separate stream or file.
* Give every statement a `timeout` so a hang is a labelled verdict, not a Ctrl-C.
* Related: [[prod-incident-instrument-check]] — validate the instrument before trusting it.
