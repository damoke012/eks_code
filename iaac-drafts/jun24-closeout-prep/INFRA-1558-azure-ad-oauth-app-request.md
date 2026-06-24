# INFRA-1558 — Azure AD OAuth app registration for Grafana SSO

| Field | Value |
|---|---|
| Ticket | INFRA-1558 (sub-ticket of INFRA-1520) |
| Audience | IT lead / Application Administrator on USXPress Azure AD tenant |
| Tenant | USXPress (`bbb5a66d-5c9f-482a-969a-a40304b6bc8d`) |
| App purpose | Single sign-on for on-prem Grafana at `https://grafana.op-dev.usxpress.io` |
| Blocker on our side | None — Grafana is operational, SSO config skeleton already shipped (PR #63), `enabled: false` flips to `true` once app reg is in hand |
| Time impact for IT | ~10-15 min in the Azure portal |

## Why we need this

The on-prem `op-usxpress-dev` cluster runs Grafana at `https://grafana.op-dev.usxpress.io`. Today it uses local Grafana admin authentication; we want to flip it to corporate Azure AD SSO so:

- Engineers use their existing USXPress AAD credentials (no second password to manage)
- We can do group-based RBAC inside Grafana driven by AAD group claims
- Aligns with the corporate identity strategy and ADR-001 Decision 2 (observability Phase 0)

We've already shipped the Grafana configuration to enable Azure AD OIDC; it's currently gated behind `enabled: false` waiting on the app registration to land. As soon as we receive the Application (client) ID and a client secret, we flip the flag and SSO is live.

## What we're asking for

A standard OAuth 2.0 / OIDC application registration in the USXPress AAD tenant with the following exact configuration:

### App name and description

- **Display name:** `Grafana — op-usxpress-dev (on-prem)`
- **Description:** `On-prem Grafana dashboard SSO for Cloud Platform team — INFRA-1558`

### Account types

- **Supported account types:** Accounts in this organizational directory only (Single tenant)
- Tenant: USXPress (`bbb5a66d-5c9f-482a-969a-a40304b6bc8d`)

### Redirect URI

- **Platform:** Web
- **Redirect URI:** `https://grafana.op-dev.usxpress.io/login/azuread`

(This is the Grafana-side OAuth callback; the path `/login/azuread` is fixed by the Grafana Azure AD provider.)

### Front-channel logout URL (optional but recommended)

- **Logout URL:** `https://grafana.op-dev.usxpress.io/logout`

### API permissions

These are standard Microsoft Graph delegated permissions for SSO:

- `openid` (delegated)
- `email` (delegated)
- `profile` (delegated)
- `User.Read` (delegated, Microsoft Graph)
- `GroupMember.Read.All` (delegated, Microsoft Graph) — required so Grafana can read the user's group memberships for RBAC

Admin consent: **required** for `GroupMember.Read.All`. Please grant tenant-wide consent at registration time so we don't get the consent prompt on every login.

### Token configuration — group claims

Under **Token configuration → Add groups claim**:

- Group types to include: **Security groups**
- Customize token properties: emit `groupID` (sAMAccountName is fine but not necessary)
- Claim emitted to: **Access token** and **ID token**

This is how Grafana receives the user's AAD groups for role mapping.

### Client secret

- **Type:** Client secret (not certificate)
- **Description:** `Grafana on-prem SSO 2026-06-24`
- **Expiry:** 12 months (we'll rotate before expiry; bake the rotation into a calendar reminder)

Please provide the secret **value** (the secret itself, not the ID) — secret is only visible in the portal at creation time and we need it for the cluster configuration.

### Tenant-wide admin consent

- Required for `GroupMember.Read.All` (above) — please grant at registration

## What we need delivered back

Three values, ideally via a secure channel (USXPress 1Password vault, encrypted email, or hand-delivery; **not** plain Teams/Slack):

| Value | Where it goes |
|---|---|
| **Application (client) ID** | Grafana config (non-secret, can ship in plaintext) |
| **Directory (tenant) ID** | We already have: `bbb5a66d-5c9f-482a-969a-a40304b6bc8d` (please confirm) |
| **Client secret value** | AWS Secrets Manager `op-usxpress-dev/platform/grafana/azure-ad` (we already have the SM secret created with placeholder values from earlier setup) |

We'll write the secret value via `aws secretsmanager put-secret-value` from a workstation; nobody needs to send it through the cluster directly.

## What happens when we get it back

```bash
# (1) Update the AWS SM secret with the real values
aws --profile usx-dev secretsmanager put-secret-value \
  --secret-id op-usxpress-dev/platform/grafana/azure-ad \
  --secret-string '{"client_id":"<APP-ID>","client_secret":"<SECRET-VALUE>"}'

# (2) Flip enabled: false -> true in the Grafana HelmRelease values
# (small PR against variant-inc/iaac-talos-flux-platform op-dev)

# (3) Flux reconcile -> Grafana pod restarts -> SSO live
```

End-to-end test: hit `https://grafana.op-dev.usxpress.io` in a browser, expect redirect to login.microsoftonline.com, login with corporate creds, land back at Grafana logged in as the corporate identity.

## Sample message to send IT

> Hey [IT lead name] — need an Azure AD OAuth app registered on the USXPress tenant for on-prem Grafana SSO. Standard OIDC pattern, ~10-15 min in the portal. Full spec attached.
> 
> **Tenant:** USXPress (`bbb5a66d-5c9f-482a-969a-a40304b6bc8d`)
> **App name:** `Grafana — op-usxpress-dev (on-prem)`
> **Redirect URI:** `https://grafana.op-dev.usxpress.io/login/azuread`
> **API permissions:** openid, email, profile, User.Read, GroupMember.Read.All (tenant-wide admin consent required for the last one)
> **Token config:** groups claim emitted in access + ID tokens
> **Client secret:** 12-month expiry, value sent back via 1Password vault
> 
> Tracking under INFRA-1558. Happy to walk through the portal flow together if easier than back-and-forth. Cluster is on-prem in our DC, no AAD-side concerns.

## Acceptance criteria for closing INFRA-1558

1. App registration exists in the USXPress AAD tenant with the spec above
2. Application (client) ID delivered to Doke
3. Client secret value delivered to a secure channel
4. AWS SM secret `op-usxpress-dev/platform/grafana/azure-ad` populated with real values
5. Grafana HelmRelease values flipped `enabled: false` → `true` (small PR)
6. Live login test: corporate email/password → AAD MFA → Grafana logged in

## Jira close-out comment template

```
2026-MM-DD HH:MM UTC — Azure AD SSO live.
- App registration: <Application (client) ID> in USXPress AAD tenant
- Secret in AWS SM: op-usxpress-dev/platform/grafana/azure-ad populated
- Grafana HelmRelease flipped enabled: true via variant-inc/iaac-talos-flux-platform PR #<N>
- End-to-end test: Doke logged in via corporate AAD credentials at https://grafana.op-dev.usxpress.io
- Group claims arriving in token; RBAC config (next phase work) tracked separately
- Closes the last gap from observability Phase 4 / INFRA-1520
Parent ticket INFRA-1520 stays Done; this sub-ticket Done.
```

Transition to Done.

## Related

- [[observability-phase0-locked-jun24]] — ADR-001 Decision 2 (Grafana SSO target)
- [[reference-usx-azure-ad-tenant]] — tenant ID source of truth
- [[feedback-never-accept-pasted-secrets]] — applies; secret value MUST come via secure channel, never pasted in chat
