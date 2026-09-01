Round 1 — `6edadb0` verified against the live accounts.

Good work, and thank you for pulling the rename out. Everything I raised is addressed, and I verified each one rather than taking the summary's word for it.

**Cleared ✅**

- **Prod account ID.** `937464026810` in all three workflows. The value in the ticket was mine and it was wrong — `786352483360` is the **playground** account (`infra-playground` / `playground` profiles), so the original would have pointed prod's OIDC role at a throwaway account. I have corrected the ticket.
- **The `*)` arms `exit 1` on an unknown environment** rather than defaulting to one. That is the right call and better than what the AC asked for.
- **`secrets.AWS_ACCOUNT_ID` is gone** (lines 134-135). That also repairs the regression #18 introduces in `secret.yaml`, so the two PRs no longer undo each other. Whichever merges second is now safe.
- **Guardrail regex.** Seven cases, run with `grep -qiP`, output in the PR body. Asking specifically because my own first check for unguarded DROPs used `git grep` without `-P`, silently ignored the lookahead and reported a clean zero. Yours actually ran.
- **`apply.sh` empty vs unset.** `[ -z "${!var:-}" ]` catches both, so the empty-string ConfigMap values in the QA and prod overlays will refuse correctly. That answers the question I had.
- **The meta-store guard** — `[ "$APP_HOST" = "$PG_HOST" ] && [ "$APP_DB" = "$PG_DB" ]`. Good.
- **ExternalSecret indices.** QA patches 1→4 and prod patches 2→4 — different starting points, which is consistent with prod having been short an index. Your two summary lines contradicted each other on this ("not addressed here" and then "also fixed"), but the code is right and your kustomize render covers it. The prose was wrong, not the change.
- **Dev overlay.** Your reasoning holds: dev runs the GitHub Actions path, not `apply.sh` under Argo CD. Dev and QA are two different delivery mechanisms, so no dev overlay is needed here.
- **AGENTS.md** removed.

**Still open — one, and it is small**

1. **(BLOCKER) `${ENV}/risingwave-2/*` resolves to nothing in QA.**

   `pipeline.yaml:70,81` become `op-usxpress-${ENV}/risingwave-2/postgres` and `.../root`. Verified in each account, 2026-09-01:

   | | `<env>/risingwave/*` | `<env>/risingwave-2/*` |
   |---|---|---|
   | dev (700736442855) | EXISTS | EXISTS |
   | qa (527101283767) | EXISTS | **absent** |
   | prod (937464026810) | absent — Terraform not run yet | absent |

   `risingwave-2` only exists in dev. So the first QA run of this workflow fails on a secret that is not there. Prod's row is expected and is not a defect in this PR — INFRA-1674 creates those.

   Making the path dynamic is right, and failing loudly beats silently reading another environment's secret. But the namespace segment is not uniform across environments, so it needs the same treatment as the account ID — mapped, not interpolated:

   ```bash
   case "${ENV}" in
     dev)  AWS_ACCOUNT_ID="700736442855"; RW_NS="risingwave-2" ;;
     qa)   AWS_ACCOUNT_ID="527101283767"; RW_NS="risingwave" ;;
     prod) AWS_ACCOUNT_ID="937464026810"; RW_NS="risingwave" ;;
     *)    echo "::error::Unknown environment '${ENV}'"; exit 1 ;;
   esac
   ```

   then `--secret-id "op-usxpress-${ENV}/${RW_NS}/postgres"`.

   That keeps dev on the path it uses today and needs no sign-off from Tim, because nothing about dev changes. It also means the `risingwave-2` → `risingwave` rename you deferred is now **required for QA to work**, not optional — worth saying out loud so it is not discovered on the first QA run.

**Confirm before merge**

- Which namespace should the QA and prod pipeline read from? I believe `risingwave`, since that is the only one that exists there — but you and Tim own that call, not me.
- Test-plan items 3 and 4 are still unchecked. Item 4 in particular (`.sql` refused when `POSTGRES_SERVER` is empty) is the one I would most like to see actually run, rather than reasoned about.

Once the `RW_NS` mapping is in, I am happy for this to merge.
