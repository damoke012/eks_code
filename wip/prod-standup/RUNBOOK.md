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

**Updated 2026-07-24 after `validate-register.sh` — 3 of 5 self-resolved.**

| Key | Value / Placeholder | Owner | Status |
|---|---|---|---|
| Prod AWS account | **`937464026810`** | — | ✅ VERIFIED via `sts get-caller-identity` |
| DNS domain | **`usxpress-prod.com`** | — | ✅ RESOLVED — Route53 zone in prod acct |
| State bucket | `lazy-tf-state-ipp58n854uhpw13x` | — | ✅ likely (QA scheme); confirm holds `iaac/talos` |
| Prod VIP | **`10.10.82.52`** | Platform (us) | ✅ RESOLVED — self-assigned on vLAN 82 (dev .50/qa .51/prod .52), verified free. Notify networking, don't ask. |
| Node IPs | DHCP | — | ✅ N/A — nodes DHCP on the vLAN (QA pattern); no static list |
| **vSphere placement** | `USXD1NTXPROD-SC1` / `vLAN 82 Prod` / dedicated folder | Platform (us) | ✅ RESOLVED — prod-designated infra (names say PROD); QA co-tenants. See capacity gate below. |
| Datastore capacity | — | Doke | ⚠️ PRE-APPLY GATE — QA squats on the same datastore; verify headroom for prod's ~5 TB before apply. |
| Talosconfig ARN | `...talosconfig-TBD-PROD` | (build-time) | seeded during §3 |
| IRSA role + OIDC bucket | empty | Cloud | phase 2 — greenfield, not blocking |
| **Octopus prod environment** | MISSING | **Octopus admin (us)** | ⛔ OPEN — no `prod` env in Spaces-2; create it + add to `iaac-talos` lifecycle. Ours, not a team ask. |

**`add-prod-vars.py --apply` refuses to run while any `TBD-PROD` remains.** Fill the
register, re-run `--diff-qa` to sanity-check drift, then apply.

---

## 2. Prerequisites (parallel with §1, no blockers)

- [ ] **E2 done on op-qa** — foreign-env literals fixed BEFORE cutting op-prod from
      that branch, or prod inherits every one. See `wip/prod-standup/E2-op-qa-commands.md`.
- [x] **Octopus prod environment exists** — it's named **`production`** (`Environments-41`),
      NOT `prod` (discovered 2026-07-24 via `--list-envs`; script default updated).
- [ ] **iaac-talos lifecycle includes a `production` phase.** The env existing ≠ the
      project deploys to it. Variable scoping works either way, but the deploy step needs
      the lifecycle to have a `production` phase (QA phase = `Environments-602`). Add the
      phase if absent. This is config we own, not a team ask.
      → checked automatically by `preflight-deploy.py` (§3.5), along with whether an
      earlier REQUIRED phase would block promotion to prod.
- [ ] **`op-prod` branch** of iaac-talos-flux-platform exists (Flux bootstrap target).
- [ ] **`clusters/op-usxpress-prod/`** in iaac-talos-flux-cluster.

### Pre-apply gate — datastore capacity (NEW, prod-ready)

Prod shares `USXD1NTXPROD-SC1` with QA (QA is co-tenanting on prod's datastore).
Prod's footprint lands ON TOP of QA's, so confirm headroom before apply — a datastore
that fills mid-provision leaves half-built VMs, the physical-layer version of the
green-object/no-effect trap. Rough prod ask: 13 VMs, ~5 TB incl. Ceph
(app pool 5×(300+500) = 4 TB dominates).

```bash
# If govc is available on WSL (vSphere creds are already in Octopus):
export GOVC_URL=... GOVC_USERNAME=... GOVC_INSECURE=1   # from Octopus vsphere vars
govc datastore.info USXD1NTXPROD-SC1        # Free vs Capacity — need >~5 TB free
# No govc? Read it from the vSphere UI: Datastores → USXD1NTXPROD-SC1 → Free space.
```

If headroom is tight, either free space, resize the application pool's Ceph disks
down for the first cut, or place prod on a different datastore with room.

---

## 3. Build order (Octopus-driven)

1. Resolve §1 register → fill `prod.tfvars` + `add-prod-vars.py`, drop all TBD.
2. `python3 add-prod-vars.py --diff-qa` → eyeball prod-vs-QA drift.
3. `python3 add-prod-vars.py --apply` → writes prod-scoped Octopus vars (backs up first).
4. **`TfApply` stays FALSE for the first Octopus run** — get a real plan gate on prod
   even though QA runs applies ungated. Read the plan before flipping it true.
5. **Seed the build-time SM secrets** in acct 937464026810, then put each real ARN
   (with AWS's random suffix) into its Octopus var — this clears the last guards:
   - `op-usxpress-prod/talosconfig` — from `talosctl gen config`
   - `op-usxpress-prod/platform/grafana` — grafana admin (generate a password)
   - `op-usxpress-prod/platform/grafana/azure-ad` — PLACEHOLDER wrapper + ignore_changes
     (Entra SSO, A1; Grafana boots without it, real value dropped by Entra team later)
   ⚠️ CONFIRM against the actual iaac-talos TF module whether these three are
   *created by* Terraform (ARN would be computed, not an input) or seeded first and
   passed in. QA passes them as input ARNs → seed-first is the working assumption.
6. `TfApply=true` → Octopus applies. Watch the task log: confirm the worker role
   authenticates and every `TF_VAR_*` lands (not defaulted/blank).
7. Flux bootstrap against `op-prod` → platform stack reconciles.

---

## 3.5 Deploy gate — run before creating the release

Steps 1–3 of the build order are DONE (vars applied 2026-07-27, `clusters/op-usxpress-prod/`
merged via PR #28, `op-prod` platform branch cut). What stands between here and step 6 is
the gate below.

```bash
# On WSL — the codespace has no Octopus credential (deliberate token isolation).
python3 preflight-deploy.py        # read-only; exit 0 = automated gates pass
```

| Gate | Check | Why it matters |
|---|---|---|
| P1 | `TfApply` not already `true` for prod | `deploy.ps1:113` gates apply on the literal string; a stale `true` = ungated prod apply |
| P2 | lifecycle reaches `production` | env exists ≠ project deploys there; also flags a REQUIRED earlier phase blocking promotion |
| P3 | no step env-scoped to exclude prod | a skipped step reports SUCCESS — the invisible failure |
| P4 | 29 prod vars present, no `TBD-PROD`, `enable_irsa=false` | proves what `--apply` actually wrote |
| P5 | no dev/qa literal in a prod value | gate B5, applied to Octopus instead of git |
| — | **datastore headroom** | MANUAL, vSphere UI — see §2 pre-apply gate |

**`TfApply` blast radius.** The variable is *unscoped* (all environments), so flipping it
true to apply prod also arms dev and qa for that window. Prefer: **add a `production`-scoped
`TfApply=true`** (most specific scope wins), apply, then **delete that scoped entry** — the
global stays `false` throughout and no other env is ever armed. Either way it must not be
left armed. Re-deploys read variables fresh at deploy time (not snapshotted at release
creation), so flip-then-redeploy works without cutting a new release.

**Then, in order:** create release off `op-prod` → deploy to `production` with `TfApply`
not true → read the plan (expect **all creates, 0 destroys**; any destroy = stop) → arm
`TfApply` → redeploy → cluster up → disarm `TfApply` → §4 gates.

Phase 1 needs **no secrets and no IRSA bootstrap**. It delivers *a cluster that exists*
(Talos + Flux + AWS-free core). It does **not** deliver a functional platform — everything
AWS-dependent waits on the cloud IRSA ask (`CLOUD-IRSA-ASK.md`). Do not let a green phase-1
deploy be read as "prod is up".

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
