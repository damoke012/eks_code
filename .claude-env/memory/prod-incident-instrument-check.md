---
name: prod-incident-instrument-check
description: Validate the measuring instrument before trusting a prod finding — three outages have now been prolonged by an instrument that could not see the failure
metadata: 
  node_type: memory
  type: feedback
  originSessionId: e3125f37-c991-4364-adf2-b40770a2d61c
  modified: 2026-08-11T01:05:21.040Z
---

**Before treating a measurement as evidence, prove the instrument can see the thing you're measuring.**
Three separate prod incidents have now been prolonged by this, twice producing a false all-clear.

**How to apply — check these first, every time:**

1. **Does the app even log what you're grepping for?** `enterprise/orders-api` runs with
   `otel.logging.enabled: false` and logs **no HTTP requests at all**. On 2026-08-10 "no `IDX10214`
   in 2 hours" was read as recovery while **100% of requests were 401** — visible only in the
   `istio-proxy` access log. Absence of an error line is not evidence of health.
2. **Match the parser to the format.** The istio access log is **JSON**; a `grep ' 401 '` returns
   zero and looks like success. Use `jq -r .response_code`, and sanity-check against a raw sample
   line before believing a count.
3. **Validate the probe against a known-good AND known-bad target.** `cat < /dev/tcp/H/P` blocks on
   read, so healthy connections reported `timeout` (2026-07-30 Atlas). Use
   `exec 3<>/dev/tcp/H/P`, which returns on handshake.
4. **Check timestamps before treating a log line as current.** `--tail` surfaces history; a CoreDNS
   `i/o timeout` from hours earlier was read as live. A console reporting a licence `"status":"active"`
   was a **cached value from 16 days before expiry**.
5. **A result that contradicts a known fact means the instrument is wrong, not the fact.**
6. **Read timezones explicitly.** Grafana rendered EDT while CloudTrail and Kubernetes rendered UTC;
   a report labelled "17:24 UTC" was actually EDT, which put the trigger *before* its own cause and
   nearly inverted the timeline.
7. **`--kubeconfig=~/...` does not tilde-expand** — kubectl silently reads a missing file and returns
   an **empty config**, not an error. Symptoms: `clusters: null`, `current-context must exist in order
   to minify`, `x509: certificate signed by unknown authority`. Use `$HOME`.
8. **A green status proves the mechanism ran, not that the value is right** — ESO `SecretSynced`,
   Octopus `Success` with `TfApply=false`, Flux `Ready` on `conditions[0]` (which may not be the Ready
   condition — use the plain `kubectl get` printer columns).

**And before changing anything in prod: prove the fix works first.** On 2026-08-10 a token-acquisition
test showed the proposed config change would have failed for every consumer
(`AADSTS501051`) — it stopped a change being rolled out to 18 teams. Read-only reproduction of the
failing call is nearly always possible; do it. See [[dx-entra-app-recreation]].

Related: [[no-test-pods-in-prod]], [[eso-secretsynced-not-content-check]], [[octopus-green-but-no-apply]].

**2026-09-01 — two probes in one script, both reporting absence that was false.**
`rw-prod-status.sh` was written to answer "is RisingWave done on prod" and got two of
eleven gates wrong in its first run:

- `aws secretsmanager list-secrets --filters Key=name,Values=op-usxpress-prod/risingwave/`
  returned **zero** minutes after the Terraform apply log printed all five secret ARNs.
  The `name` filter tokenises its value; it does not prefix-match a slashed path. The
  fix is `describe-secret --secret-id <exact name>` per secret — which the older
  `wire-prod-risingwave.py` already did. A newer script regressed a solved problem.
- The Gateway check was pinned to `-n istio-ingress` and reported `tcp-passthrough`
  absent on a cluster where we had confirmed it live a day earlier. Searching all
  namespaces found it.

**How to apply:** when a fresh check disagrees with something already proven, suspect the
check first — and before writing a new probe, look for an existing script that measures
the same thing and copy its method. Both defects were "empty result from the wrong
selector", which CLAUDE.md rule 5 already names. Neither survived contact with evidence
we already had in hand. See [[proxy-is-not-the-property]].
