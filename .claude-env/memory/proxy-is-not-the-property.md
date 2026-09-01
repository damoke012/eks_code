---
name: proxy-is-not-the-property
description: The recurring self-inflicted error — measuring something adjacent to the property in question and reporting the proxy's answer as the property's; four instances, each reversed by one direct check
metadata:
  type: feedback
---

Four times now a confident wrong answer came from measuring a proxy instead of the thing:

| Question | Proxy used | Verdict | Direct check that reversed it |
|---|---|---|---|
| Is master's SQL parameterised? | count of `%VAR%` tokens | "Idris regressed Tim's work" | reading the file — `secret kafka_api_key` scores zero `%` and is *more* parameterised |
| Which bucket did Terraform build? | AWS resource tags | "TF built the empty one" | creation dates + the IRSA policy's `Resource` list — the *untagged* bucket is TF's; the provider sets no `default_tags` |
| Are there unguarded DROPs? | `git grep` without `-P` | "zero findings" | `grep -rPn` — the lookahead had been silently ignored |
| Does op-prod have Istio Gateways? | `kubectl get gateway` | zero rows | `gateways.networking.istio.io` — it had resolved the Gateway API CRD instead |
| Is RisingWave already wired into prod's infra.yaml? | substring `risingwave-onprem` | "already wired — nothing to do" | parsing the documents — the match was inside the header comment *"does not exist in iaac-risingwave-onprem yet"* |

**Why:** every one of these produced a *clean, confident* result. Nothing errored. The proxy
answered its own question correctly and the answer was attributed to a different question.
This is the same family as [[adjacent-step-green-signals]] and
[[transport-failure-not-a-verdict]], but self-inflicted at the point of measurement rather
than inherited from a tool.

**How to apply:** before reporting a property, name the direct evidence for it. Tags are not
provenance — creation time and the policy that references the resource are. A token count is
not parameterisation — the file is. An empty result is only absence once the selector and the
resource kind are confirmed to resolve. When a proxy is the only thing available, say which
proxy was used and what it cannot see. Related:
[[eso-secretsynced-not-content-check]], [[merged-defect-authorizes-itself]].
