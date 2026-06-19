# Octopus On-Prem — STATE
*Last updated 2026-05-27. No material change today; reference for ongoing constraints.*

## Where it stands
Vendored Octopus worker chart deployed via Flux. `variant-inc/iaac-octopus-onprem` repo created (per Vibin's decision 2026-04-24) — release-mirror workflow + enrollment manifest + fork-side templates live there. Has `OCTOPUS_API_KEY` secret set. Per-project and `--all` dispatch working.

## Key links / repos
- `variant-inc/iaac-octopus-onprem` — on-prem team-owned (NOT `iaac-octopus-config` which is cloud-team).
- Local working copy: [`../../repos/iaac-octopus-overrides/`](../../repos/iaac-octopus-overrides/) — committed in eks_code's tree.

## TfApply discipline (CRITICAL)
- iaac-talos Octopus project: `TfApply` variable defaults to `false` (plan-only).
- To apply: flip TfApply=true, deploy release, then flip back to false (safety default).
- **Always confirm value before assuming an apply ran.**

## Open items
| Item | Owner | Notes |
|------|-------|-------|
| Confirm TfApply=false after release 1.143 (IAM role apply) | Doke | Currently not verified post-deploy. |
| OnPremise Octopus Space + on-prem worker pool — final creation | Doke + Steve | Pending. |
| API key rotation | Doke | Followup; not urgent. |
| Help Steve scope Idris's Octopus access | Doke + Steve | Meta-task; needs scoping conversation. |

## Conventions
- **Releases via GHA workflow only** — never manual API calls or curl POSTs.
- After a fix → trigger release via GHA `release-mirror.py` workflow → user deploys from Octopus UI. **Don't call deployments API directly.**
- Stale release re-mirror → add `--force` to mirror-release.py, **not** curl DELETE.

## Risk / watch-outs
- Don't skip the TfApply=false flip-back — leaving it true risks accidental applies on the next deploy.
- iaac-talos PR base is `feature/op-usxpress-dev` (NOT master). Master is 0.0.8 (stale); cluster runs `feature/op-usxpress-dev` (0.1.0). PRing off master gives a catastrophic plan diff.
