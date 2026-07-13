# INFRA-1591: Platform SSO via Entra ID — reusable dev service-account pattern (RisingWave first consumer)

**Type**: Story
**Priority**: High
**Component**: Identity / AAD / Platform
**Reporter**: Doke
**Assignee**: Idris
**Epic**: INFRA-1559 (AAD identity strategy)
**Labels**: sso, entra, aad, risingwave, discovery
**Created**: 2026-07-13

## Problem

RisingWave SSO needs Entra ID (Azure): client credentials, client secret, tenant ID. Rather than wire this one-off for RisingWave, build a **reusable platform SSO pattern** using a **dev service-account Entra app registration** that replicates to other apps. RisingWave is the first consumer.

## Scope

1. **Discovery first** (first time doing SSO here): produce a Confluence/JIRA design page for the pattern.
2. Define the dev service-account Entra app registration + how apps consume it (client creds/secret/tenant).
3. Wire RisingWave SSO as the first consumer.
4. Confirm Azure access now available (granted 2026-07-13) before requesting a design meeting.

## Acceptance criteria

- Design page published + team-aligned.
- Reusable dev service-account Entra SSO pattern defined.
- RisingWave SSO working against it.
- Pattern documented as repeatable for future apps.

## Refs

- `wip/standup-2026-07-13/standup-extract.md` (T3)
- memory: rw-platform-sso-entra
