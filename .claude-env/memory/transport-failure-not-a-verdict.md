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

## 2026-10-20 — and the other half: don't run a test a known blocker already explains

Two things happened in one command against op-qa, and only one of them is a finding.

**Not a finding.** `istio-ingressgateway` has neither `curl` nor `getent`:
`exec: "curl": executable file not found in $PATH`. That is **NOT MEASURED** about the
network — the probe never left the pod. An Istio proxy image is minimal; so are
cert-manager, external-secrets and the Flux controllers. Candidates that usually do carry
tools: `argocd-repo-server`, `grafana`. Test for the binary before trusting the silence.

**The finding, and it is about sequencing.** The connection test was going to measure whether
on-prem can reach an AWS PrivateLink endpoint — while we already knew the endpoint's security
group admits `10.16.0.0/20` **only**. A timeout was fully explained *before the test ran*, so
the test could return no information: success was impossible and failure was ambiguous
between "no route" and "the rule we already know about".

**How to apply.** Before running a probe, ask what each possible result would change. If one
outcome is impossible and the other is already explained by a known cause, **remove the known
cause first, then measure.** Otherwise the test burns a round trip and, worse, its predicted
failure gets quoted later as evidence of something it never measured.

Related: [[proxy-is-not-the-property]], [[a-guard-can-measure-the-wrong-thing]].

## 2026-10-27 — a whitelist of failures is never complete

`scripts/check-authenticator-webhook-file.sh` reported prod's webhook kubeconfig **ABSENT on
10.10.82.51** and printed *"Do NOT land the apiserver flag: it would not restart on those
nodes."* The node was simply unreachable — a dead VPN:
`rpc error: code = Unavailable ... transport: Error while dialing: dial`.

The script **did** try to handle this. It had a NOT MEASURED branch keyed on
`x509|handshake|certificate|unauthenticated|deadline`, and everything that matched none of
them fell through to `ABSENT`. `code = Unavailable` is on no such list.

**Why:** this is the same class as the 2026-08-28 `psql` case, but with the trap one level
deeper — the author knew transport failures existed and still got it wrong, because the
structure was *enumerate the ways it can fail*. That list can always be one error string
short, and the default branch was the damaging verdict. The failure mode was also
self-concealing: it blocked a correct action, which looks like caution rather than a bug.

**How to apply:**
* **Enumerate the one way a probe SUCCEEDS; everything else is NOT MEASURED.** Never
  enumerate failures with a verdict as the default branch.
* A negative verdict needs **positive evidence**: here, ABSENT requires either a listing that
  exited `0` without the filename, or an error that explicitly says the directory is missing.
* **Check the exit code**, not only the text — the original matched text and ignored `$?`.
* The same run also fell back from three control-plane nodes to the endpoint alone, said
  *"WARNING: that is ONE node, not the control plane"*, and still left `PASS` reachable. A
  warning nobody must act on is not a guard: make the degraded path **unable** to emit the
  reassuring verdict. See [[a-guard-can-measure-the-wrong-thing]].
* When a probe against on-prem fails oddly, check the VPN **first**:
  `bash -c 'echo > /dev/tcp/10.10.82.51/50000'`. Expired AWS SSO and a dropped VPN are the
  two overnight state changes that make yesterday's proven commands fail today.
