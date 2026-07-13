# INFRA-1595: Entra app-registration secret rotation — Jul–Aug 2026 expiries + runbook

**Type**: Story
**Priority**: High
**Component**: Identity / Secrets / Cloud
**Reporter**: Doke
**Assignee**: Parul
**Labels**: secrets, entra, rotation, freshservice-na
**Created**: 2026-07-13

## Problem

11 Entra ID (Azure AD) app-registration **client secrets** (`dx-{env}-usxpress-{app}`) expire Jul–Aug 2026 (soonest was `xpm-classic-auth-dx` 7/17, since negated). Rotation is manual (not automatic). We must rotate the in-use ones before expiry without a prod auth outage, and confirm/retire the stale ones with their owners.

## Scope

1. Rotate the confirmed-in-use prod secrets (usx-orders-auto-booking-handler 7/29, usx-missions-event-handler 8/1, freight-allocation-api 7/29). Method: new Azure secret → update Secrets Manager → update TF state → delete K8s secret → rerun pipeline.
2. Test DPL → dev → higher envs; do prod rotations together on a call. (DPL already validated.)
3. Confirm stale/unused registrations with owners (cc Steve) before any delete — xpm-classic (Buddy), mulesoft (Srikanth/Buddy/Jason), knx/cadex (TBD).
4. Publish the rotation **runbook** (`wip/secret-rotation/rotation-runbook-DRAFT.md`) as the signed-off playbook.

## Acceptance criteria

- All in-use prod secrets rotated before expiry; apps authenticating post-rotation.
- Stale registrations confirmed with owners (record kept) before deletion.
- Runbook published + team-reviewed.

## Refs

- `wip/secret-rotation/` (STATE + runbook), memory: entra-secret-rotation
- Follow-up: automation (separate ticket).
