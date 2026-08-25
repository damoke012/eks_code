# Entra: why does `Argo CD On-Prem` get no `groups` claim?

**Purpose:** Argo CD on the on-prem Talos clusters authenticates against Entra ID
successfully, but every token comes back without a `groups` claim, so no user can be
authorised for anything. This blocks INFRA-1639 — SSO for application teams — on
op-usxpress-dev, -qa and -prod. Everything configurable on the application side has
been set and read back; what remains is above our visibility.

**From:** Dare Oke, cloud/platform engineering (on-prem Talos clusters)
**To:** the owner of Entra tenant `bbb5a66d-5c9f-482a-969a-a40304b6bc8d` — USX identity / directory
**How your answers will be used:** to decide whether to change a tenant setting, or to
abandon group claims and authorise Argo CD on app roles instead. Either way the answer
goes into `wip/onprem-argocd/FINDINGS-2026-08-25-entra-oidc.md` and the ticket.

## Context

We registered a confidential (web) client, `Argo CD On-Prem`, app ID
`42dc0c33-4c56-47a5-b207-d119272997aa`, SP `b20084ae-9f13-4ca7-961c-b05f023fa2c2`, on
2026-08-25. Login works end to end: federated through ADFS at `usxfs.usxpress.com/adfs/ls`,
MFA, back to Argo with a valid v2.0 ID token — correct `aud`, `iss`, `tid`, live session.

The token contains: `aud, email, exp, iat, iss, name, nbf, oid, preferred_username, rh,
sid, sub, tid, uti, ver`. No `groups`, and no `_claim_names` overage pointer either.

We have already ruled out, by reading the configuration back rather than assuming:

| Checked | Result |
|---|---|
| `groupMembershipClaims: SecurityGroup` | no claim emitted |
| `groupMembershipClaims: ApplicationGroup` | no claim emitted |
| `groups` in `optionalClaims.idToken` | present |
| claims-mapping policy on the service principal | none (`claimsMappingPolicies` empty) |
| group count for the signing-in user | 42 (`getMemberGroups`, securityEnabledOnly) — well under the ~200 overage threshold |
| `appRoleAssignmentRequired` | `true`, with the group **and** the user assigned |
| redirect URIs | 3 × `web`, `spa` empty (an SPA client fails earlier, with `AADSTS9002327`) |
| Argo's `requestedIDTokenClaims` | removed — no change either way |

The tenant already runs Argo CD on Entra OIDC natively for the cloud EKS fleet
(registration `56078536-f4a3-4f92-810e-5106787019a8`, four `/auth/callback` URIs, two of
them production), so the pattern works somewhere in this tenant. We deliberately did not
reuse that registration: it serves two production clusters, has zero registered owners,
and `--web-redirect-uris` replaces the URI list wholesale.

## How to answer

Roughly 20 minutes. Please answer by **2026-08-28** if you can — an application team is
waiting on the view. Partial answers help: "I don't know" or "I'd have to check" is far
more useful than a skipped question, because it tells us where to look next. Question 1
is the one that most likely ends this on its own.

## The tenant configuration

### Does the cloud-fleet registration `56078536-f4a3-4f92-810e-5106787019a8` actually receive a `groups` claim today?

_Why this matters: it is the control. If it does, the difference between the two registrations is the answer and we stop guessing. If it does **not** — and Argo CD there is authorising on something else — then group claims have never worked in this tenant and we should copy whatever that app does instead._

>

### Is there a tenant-wide token issuance policy, or a claims-mapping policy applied at the tenant or default-service-principal level, that suppresses or filters group claims?

_Why this matters: we can read policies attached to our own service principal (there are none) but not ones applied above it._

>

### Is there a Conditional Access policy — a session control, token protection, or app-enforced restriction — that applies to this application or to on-prem-federated users generally?

>

### Does the ADFS federation at `usxfs.usxpress.com` change what Entra will emit for a federated user, compared with a cloud-only user?

_Why this matters: if it does, a cloud-only test account would get the claim and a federated one would not, which is a five-minute experiment rather than a policy hunt._

>

### Is this tenant licensed for Entra ID P1 or P2?

_Why this matters: assigning a **group** to an application's app role requires P1. Assigning individual users does not. This decides whether the app-role fallback below scales or is a per-person chore._

>

## The fallback, if group claims are not available

We can define app roles on our own registration and have Entra emit a `roles` claim
instead — a different issuance path from directory group membership, and entirely inside
the application we own. Argo CD reads RBAC subjects from whichever claims we tell it to.

### Is there any reason we should not use app roles for this?

_Why this matters: if there is a house standard for application authorisation we don't know about, we would rather adopt it than invent a second pattern._

>

### If we use app roles, who assigns groups to them — us, or you?

_Why this matters: it decides whether onboarding a new application team is a platform action or a ticket to your team, which changes what we write into the onboarding doc._

>

### Is `emit_as_roles` set as an `additionalProperties` value on the `groups` optional claim anywhere by policy?

_Why this matters: that option deliberately moves group values out of `groups` and into `roles`. If it is set by convention here, "no groups claim" is working as designed and we have been looking in the wrong claim the whole time._

>

## Who owns what

### Who should we go to for this class of question in future — app registrations, claims, Conditional Access?

_Why this matters: we have three clusters and a growing number of application teams; we would like to stop routing identity questions by asking around._

>

### Are we expected to register our own applications, or should platform registrations go through a request process?

_Why this matters: we created `Argo CD On-Prem` ourselves because we had the rights to. If that was not the intended path we would like to know now, while there is one of them and not ten._

>

## Anything else?

Anything we did not ask that we should know about how this tenant issues claims, or about
how other applications here handle authorisation?

>

---

**Raised by:** INFRA-1639. Full technical record:
`wip/onprem-argocd/FINDINGS-2026-08-25-entra-oidc.md`.
