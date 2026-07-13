# INFRA-1594: AWS EKS Kubernetes upgrade — assess current version + automate fleet-style rollout

**Type**: Story
**Priority**: Medium
**Component**: Cloud / EKS
**Reporter**: Doke
**Assignee**: Mark (new) — Parul + Rohit guide
**Labels**: eks, k8s-upgrade, cloud, automation
**Created**: 2026-07-13

## Problem

Confirm what Kubernetes version our AWS EKS clusters run (~1.34/1.35) vs the latest AWS-supported version, and whether we're behind. Plan an **automated (fleet-style)** upgrade rather than hand-running it, flowing dev → QA/staging → prod. Parul has end-to-end upgrade documentation to build on. Good ramp area for the new team member (Mark) with Parul/Rohit guiding.

## Scope

1. Report current EKS version per cluster vs AWS-supported latest (gap analysis).
2. Review Parul's existing upgrade docs; identify manual steps to automate.
3. Design an automated/fleet upgrade approach.
4. Sequenced rollout plan dev → QA/staging → prod; set up a call by urgency.

## Acceptance criteria

- Current-vs-supported version report.
- Automated upgrade approach documented.
- Upgrade runbook + per-env rollout plan.

## Refs

- `wip/standup-2026-07-13/standup-extract.md` (T6)
- memory: eks-k8s-upgrade
