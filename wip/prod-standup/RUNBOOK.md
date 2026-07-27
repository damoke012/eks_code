# op-usxpress-prod stand-up — runbook

**Owner:** Doke · **Tickets:** INFRA-1589 (automation), INFRA-1621 (prod gaps)
**Started:** 2026-07-24 · **Deploy path:** Octopus ONLY (never local `terraform apply`)

This is the first real execution of the teardown→rebuild path. QA was never torn
down, so nothing here has been proven end-to-end — treat every gate as load-bearing.

---

## 0. What "kick off prod" actually means today

We CAN build all the prod scaffolding now. We CANNOT fire a real apply until the
placeholder register (§1) is fully resolved. The scaffolding is written so that a
premature apply **fails at init**, not silently on a wrong value — that's the whole
design (INFRA-1623: a wrong value that deploys clean is worse than one that breaks).

Artifacts produced this session (in `wip/prod-standup/`):
- `prod.tfvars` — E5, modelled on the verified QA tfvars
- `add-prod-vars.py` — E4, prod Octopus vars, dry-run default + TBD guard + `--diff-qa`

---

## 1. Placeholder register — MUST be real before apply

Nothing below can be guessed. Each blocks the build; each has a named owner.

| Key | Placeholder | Owner | Notes |
|---|---|---|---|
| Prod AWS account | `937464026810` **(inferred — CONFIRM)** | Cloud | "on-prem reuses cloud per-env account": dev→700736442855, qa→527101283767. Consistent, but confirm before it's baked into IAM/backend. |
| Prod VIP + node IPs | `TBD-PROD-VIP` | Networking | THE dev-VIP-in-QA field. One wrong digit = 13 silent days. |
| State bucket | `TBD-PROD-STATE-BUCKET` | Cloud | Per-account; prod needs its own in 937464026810. |
| DNS domain | (external-dns/ingress/OIDC) | Networking / CySec | Needed for external-dns txtOwnerId, ingress hosts, OIDC CloudFront. |
| vSphere placement | `TBD-PROD-DATASTORE` / `-NETWORK` / `-CONTENT-LIB` | Infra | QA rides vLAN 82; prod may be dedicated — do NOT assume. |
| Talosconfig ARN | `...talosconfig-TBD-PROD` | (build-time) | Created during §3; ARN known only after seeding. |
| IRSA role ARN + OIDC bucket | empty | Cloud | `ONPREM_BOOTSTRAP_ROLE_ARN_PROD`. Starts false; flip true phase 2. |

**`add-prod-vars.py --apply` refuses to run while any `TBD-PROD` remains.** Fill the
register, re-run `--diff-qa` to sanity-check drift, then apply.

---

## 2. Prerequisites (parallel with §1, no blockers)

- [ ] **E2 done on op-qa** — foreign-env literals fixed BEFORE cutting op-prod from
      that branch, or prod inherits every one. See `wip/prod-standup/E2-op-qa-commands.md`.
- [ ] **Octopus prod environment + lifecycle phase exists.** `add-prod-vars.py` aborts
      if `environment 'prod'` is absent. Confirm the iaac-talos lifecycle has a prod
      phase (the QA phase was `Environments-602`; prod is a different id).
- [ ] **`op-prod` branch** of iaac-talos-flux-platform exists (Flux bootstrap target).
- [ ] **`clusters/op-usxpress-prod/`** in iaac-talos-flux-cluster.

---

## 3. Build order (Octopus-driven)

1. Resolve §1 register → fill `prod.tfvars` + `add-prod-vars.py`, drop all TBD.
2. `python3 add-prod-vars.py --diff-qa` → eyeball prod-vs-QA drift.
3. `python3 add-prod-vars.py --apply` → writes prod-scoped Octopus vars (backs up first).
4. **`TfApply` stays FALSE for the first Octopus run** — get a real plan gate on prod
   even though QA runs applies ungated. Read the plan before flipping it true.
5. talosctl gen config → seed `op-usxpress-prod/talosconfig` in SM (acct 937464026810)
   → put the real ARN into the tfvar/Octopus var.
6. `TfApply=true` → Octopus applies. Watch the task log: confirm the worker role
   authenticates and every `TF_VAR_*` lands (not defaulted/blank).
7. Flux bootstrap against `op-prod` → platform stack reconciles.

---

## 4. Acceptance gates — prove the artifact, not the exit code (B1–B7)

Run ALL before declaring prod up. These are the two that would have caught INFRA-1623
(B4, B5) plus the false-negative trap (B7).

| Gate | Check | Pass |
|---|---|---|
| B1 talosconfig real | SM value starts `context:` not `PLACEHOLDER` | ✓ |
| B2 SM == mounted | `diff` SM value vs `etcd-backup` secret | only trailing-newline |
| B3 talosctl reaches prod | `talosctl -n <prod VIP> version` | server tag returned |
| B4 **snapshot in S3** | `aws s3 ls s3://etcd-snapshots-op-usxpress-prod --recursive` | ≥1 object <2h old |
| B5 **no foreign strings** | `git grep -nE "op-usxpress-(dev\|qa)\|10\.10\.82\.(50\|51)" origin/op-prod` | zero hits |
| B6 ESO valid not just synced | per-consumer functional check | value works |
| B7 Flux applied merged SHA | `flux get kustomizations` revision == merged SHA | exact match |

⚠️ **B7 first, always.** During the INFRA-1623 fix the first post-merge job ran the
STALE spec and looked identical to a real failure. Confirm the SHA before re-testing.

---

## 5. The honest risk

The full rebuild path has never run. Prod is its first execution, so expect to find
things QA never exercised because QA was only ever built forward, never from scratch.
The dev ArgoCD CRD finding (2026-07-24) is a small live example: a manifest that
"works" only because of pre-existing cluster state. Budget for discovery, not just
execution.
