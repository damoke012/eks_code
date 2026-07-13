# INFRA-1590: Deploy Wiz (eBPF sensor) on the dev cluster

> ⚠️ PROBABLE DUPLICATE of **INFRA-1505** (wiz-ebpf-onboarding-op-usxpress-dev, filed from the
> 2026-05-29 CySec call). The auto-dedup guard missed it. RECONCILE: close one as duplicate
> of the other — keep INFRA-1505 (original) or fold its scope into this one. Do NOT run both.

**Type**: Story
**Priority**: Medium
**Component**: Security / On-prem
**Reporter**: Doke
**Epic**: INFRA-472 (initiative) — or existing AAD/security epic
**Labels**: security, wiz, onprem
**Created**: 2026-07-13

> ⚠️ DEDUP CHECK: a Wiz eBPF onboarding ticket was likely filed from the 2026-05-29 CySec
> call (draft `2026-06-01-wiz-ebpf-onboarding-op-usxpress-dev.md`, under INFRA-472).
> Verify before creating — if it exists, update/assign that one instead of a duplicate.

## Problem

Wiz replaces Orca for on-prem (decided 2026-05-29 CySec call). Onboard the Wiz eBPF sensor onto the dev cluster (`op-usxpress-dev`) this week as the first cluster, in collaboration with Steve Vives (build-out lead).

## Scope

1. Deploy the Wiz eBPF sensor DaemonSet to dev (top crown-jewel hosts first).
2. Confirm required egress to wiz.io.
3. Validate runtime visibility (kube-apiserver / etcd / node coverage) with the 256Mi cap model.
4. Document for QA/prod promotion.

## Acceptance criteria

- Wiz sensor running + reporting on dev cluster.
- Egress + visibility confirmed.
- Onboarding steps documented for QA/prod.

## Refs

- `wip/standup-2026-07-13/standup-extract.md` (T2)
- 2026-05-29 networking/CySec call review
