---
name: argocd-onprem-entra-oidc
description: Argo CD SSO live on ALL THREE on-prem clusters 2026-08-25 — Entra OIDC auth + authz from the ROLES claim (groups never arrives); policy.csv subjects are app-role values
metadata:
  type: project
---

**op-dev Argo CD SSO, as of 2026-08-25.** Authentication **works and is proven**; authorization
does **not** — Entra issues a valid token with **no `groups` claim**, so `policy.csv` never
matches and `policy.default: ""` applies.

App `Argo CD On-Prem` **42dc0c33-4c56-47a5-b207-d119272997aa**, SP
**b20084ae-9f13-4ca7-961c-b05f023fa2c2**, tenant **bbb5a66d-5c9f-482a-969a-a40304b6bc8d**.
All three cluster callbacks registered, so **QA and prod need no Entra work** — only a branch PR.

**op-qa reached parity 2026-08-25** (PRs #135 + #136). Verified without a browser:
`curl https://argocd.op-qa.usxpress.io/` → 200, `/api/v1/settings` serves the Entra
`oidcConfig`, `argocd-entra-oidc` secret holds 40 bytes. DNS `.139 .23 .106`. Login itself
untested; the groups claim is a tenant-level question so QA's outcome would not change it.
op-prod: client secret IS stored (`op-usxpress-prod/platform/argocd/azure-ad`, us-east-2, 937464026810 — no permission-set grant needed, `ops-controller` could already write; region derived from evidence, not assumed). Branch NOT wired: no `configs.cm.url`, no `rbac` block, no Secrets Manager grant, and its
ClusterSecretStore is unverified (no persisted kubeconfig).
Argo v3.4.5. Dex deleted. Secret at `op-usxpress-dev/platform/argocd/azure-ad`
(**us-east-2**, account 700736442855, profile **`usx-dev`**), delivered by the existing
`admin-externalsecret.yaml` (`creationPolicy: Merge` into `argocd-secret`).

**Why:** Argo redeems the auth code **server-side**, so it needs a **confidential (web) client** —
an SPA registration fails at the callback with `AADSTS9002327`, which kills the
no-client-secret PKCE design. The cloud EKS fleet's own `Argo CD` app
(`56078536-…`, four `/auth/callback` URIs, two production, **zero owners**) already showed this;
never reuse that app — `--web-redirect-uris` replaces the list wholesale.

**How to apply:** killed so far — `ApplicationGroup`, `SecurityGroup`, and removing
`requestedIDTokenClaims`. Ruled out by readback — 42 security groups including the target one,
`groups` in `optionalClaims.idToken`, no claims-mapping policy, assignment present. What is left
is tenant-level (token issuance policy, Conditional Access, or the ADFS federation at
`usxfs.usxpress.com`) and needs the directory owner. Full detail:
`wip/onprem-argocd/FINDINGS-2026-08-25-entra-oidc.md`. See
[[identity-names-do-not-cross-systems]], [[adjacent-step-green-signals]],
[[argocd-sso-blocked-on-management-account]].


**op-prod blocked 2026-08-25.** No VirtualService for argocd, so the callback has nowhere to
land — and no route on that branch can be copied from, because all 5 belong to op-dev
([[manifests-copied-across-branches]]). Unblocks with INFRA-1663 (no prod kubeconfig).


**✅ PROVEN 2026-08-25 19:18Z — the route around the groups claim works.** Token on op-dev:
`roles: ["platform-admin"]`, `groups` still absent. The control was free and decisive —
Idris signed in six minutes earlier against the identical config holding only **default
access** and got **no** roles claim. Same app, same tenant, same federation; the
assignment is the variable. **Group-to-app-role assignment worked first try** —
`usx-cloud-admin` holds `platform-admin`, so no Entra ID P1 licence is needed and teams
are granted as groups. `emit_as_roles` was NOT set (`additionalProperties: []`) — ruled
out by reading `optionalClaims` in full, which should have come before every
`groupMembershipClaims` permutation.

**Original write-up, now confirmed:** `roles` is a separate
claim, issued from **appRoleAssignments on the service principal**, not from directory group
membership, so whatever suppresses group claims here has no reason to touch it. Argo CD's
`configs.rbac.scopes` names which claims it searches for a subject — `[roles, groups]` matches
either. The whole path is inside the registration we own, so it needs **nothing** from the
directory team. `scripts/entra-argocd-app-roles.sh` (`--inspect`/`--define`/`--assign`,
deterministic uuid5 role IDs) and `scripts/pr-argocd-rbac-app-viewer.sh --role-value`.
Assigning a **group** to an app role needs Entra ID P1; per-user assignment works on any tier
and is enough to prove the claim arrives.

**Read `optionalClaims` in full before anything else.** The `groups` optional claim takes an
`additionalProperties` value, **`emit_as_roles`**, that moves group values *out* of `groups`
and *into* `roles` by design. We verified `groups` was present in `optionalClaims.idToken` and
never printed what sat beside it — so every `groupMembershipClaims` permutation tried on
2026-08-25 may have been aimed at the wrong field. `--inspect` now dumps it first.

**The app-team view exists as a builder:** `scripts/pr-argocd-rbac-app-viewer.sh` writes
`role:app-viewer` to all three branches, scoped to the AppProject **read off each branch**,
`sync` on dev/QA and **withheld on prod**. Needs one value — the RW team's Entra group object
ID, from Idris. Ordered commands for everything remaining:
`wip/onprem-argocd/RUNBOOK-FINISH-INFRA-1639-AND-1663.md`.

**INFRA-1639 cannot close as written** ("SSO for application teams") — split it into
authentication (done on dev+QA), the claim blocker (someone else's), and the app-team view.


**How to apply.** Subjects in `policy.csv` are **app-role values**, not GUIDs, and
`configs.rbac.scopes` must be `[roles, groups]`. Every `g,` subject must be the **same
kind** — a file holding both a group object ID and a role value has one subject that can
never match, and which one is invisible from the file;
`scripts/pr-argocd-rbac-app-viewer.sh` rekeys the admin line in the same edit and asserts
this. `scripts/argocd-token-claims.sh <cluster>` needs its cluster argument and now prints
claim **values** — a claim NAME in a list proves emission, not content
([[adjacent-step-green-signals]]).


**✅ ALL THREE CLUSTERS, 2026-08-25.** op-prod completed the chain: ACME solver zone (#140)
→ `wildcard-op-prod` issued → Gateway serving op-prod (#137) → Argo route + OIDC + RBAC
(#141) → `role:app-viewer` (#142); dev and QA via #138/#139. `argocd.op-prod.usxpress.io`
resolves to 10 A records — **the first DNS record external-dns ever published on op-prod**,
after 27 days of "All records are already up to date".

**Still unexercised: `role:app-viewer`.** Idris holds the assignment
(`86486897-edd4-537d-b04f-805d6aeff583`); nobody has signed in as an application-team
member. That is the acceptance test for INFRA-1639, not our own admin access.


**Closing evidence, 2026-08-25.** `scripts/close-argocd-sso.sh <cluster>` passes on all
three: DNS verified against the nodes actually running each cluster's ingressgateway
(**7 dev / 3 qa / 10 prod**), HTTPS 200 on that cluster's own certificate, Entra issuer
served, 40-byte client secret, consistent policy. The secret's home differs by design —
op-dev merges into the chart-owned `argocd-secret` as `oidc.entra.clientSecret` (an adopted
install's `server.secretkey` had to survive); QA and prod use their own labelled
`argocd-entra-oidc/client_secret` so a chart upgrade cannot drop it.

**The only thing left for INFRA-1639 is a human sign-in by an APPLICATION-TEAM member.**
No script can establish it, and everything verified so far is platform-admin access.

**2026-09-02 — access is now managed by GROUP, three tiers, and `app-operator` exists.**
Per-user assignment was never the design; it happened because the app team's group object
ID was an open ask on Idris and never arrived. Now:

| Group | Object ID | App role | Members |
|---|---|---|---|
| `usx-cloud-admin` | b9a1ff74-efa1-4b20-be8a-8706a5ab2636 | `platform-admin` (10f51b4f-7354-5a04-bb89-e80d2769e69d) | pre-existing |
| `usx-argocd-operator` | 984faf3e-e280-490e-8ff4-a71101a73a95 | `app-operator` (19e6754e-43dc-58c2-a431-5b15b133d672) | Timothy Preble, Pujit Koirala |
| `usx-argocd-viewer` | 6bd52028-9105-4bdf-a39a-0d31a57ae53b | `app-viewer` (86486897-edd4-537d-b04f-805d6aeff583) | Jenni Ray |

`app-operator` = read + logs + sync **on all three clusters including prod** + `action/*`
(the Restart button) + resource-level delete. Doke's call 2026-09-02, a deliberate
widening of `app-viewer`, which stays read-only with sync on dev/QA only.
Built by `scripts/entra-argocd-access-groups.sh` and
`scripts/pr-argocd-rbac-operator.sh`.

**⚠️ Idris holds `app-viewer`, NOT `platform-admin`.** Read off the assignments
2026-09-02. If he is meant to be an admin, add him to `usx-cloud-admin`; that is very
likely why he was assigning people individually.

**Two gates, not one, and they are independent.**
1. `appRoleAssignmentRequired: true` — the person must hold an app role. Group membership
   satisfies it.
2. **Admin consent.** User consent is disabled tenant-wide, so the first sign-in by anyone
   who is not already consented lands on `login.microsoftonline.com/<tenant>/Consent/Request`
   — "Request sent, your admin has been notified". Pujit hit this on 2026-09-02. The fix is
   **tenant-wide consent once** on the registration, not per-request approval, or every new
   person repeats it. Needs Cloud Application Administrator or above — a higher bar than the
   app-registration write we already have.

**The `groups` optional claim carries an empty `additionalProperties`.** That is the field
`emit_as_roles` would occupy. Printed in full for the first time 2026-09-02. Not worth
chasing now that roles work, but it is the loose end behind the missing groups claim.

**Directory names are not guessable.** "Tim Wolfe" and "Jenny Ray" were both wrong — the
real users are **Timothy Preble** `tpreble@usxpress.com` and **Jenni Ray** `jlray@usxpress.com`.
Resolve a UPN with `scripts/entra-argocd-access-groups.sh --find <surname>` before scripting
anyone's access. See [[identity-names-do-not-cross-systems]].

**2026-09-02 close-out — four PRs open, one secret written.**
- `variant-inc/iaac-talos-flux-platform` **#144** (op-prod) repo SSH ExternalSecret,
  **#145/#146/#147** `role:app-operator` on op-dev/op-qa/op-prod, scoped to project `apps`.
- `repo.risingwave-pipeline.sshPrivateKey` **written** to `op-usxpress-prod/platform/argocd`
  2026-09-02 by `scripts/argocd-repo-deploy-key.sh --write`, verified by content, both
  pre-existing properties (`admin.password`, `admin.passwordMtime`) intact. **That record
  holds the Argo admin password and `put-secret-value` replaces the whole document** — only
  ever merge into it.
- Public half `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINv2YLLN860FtxCgI9sXUbPw98EjAkp61wlknLOiVfRD`
  must be added as a **read-only deploy key** on `variant-inc/risingwave-pipeline`.

**PR #144 was inert when written.** The ExternalSecret referenced a property that did not
exist — the record held only `admin.password` and `admin.passwordMtime`. It would have
merged, synced green, and left Argo CD with a credential object carrying no key. Check the
remote property exists before landing any ExternalSecret
([[eso-secretsynced-not-content-check]]).

**✅ ALL FOUR MERGED AND LIVE ON PROD 2026-09-02.** `op-prod` moved
`7f0d3b7` → `b0cd4c4`; `argocd-rbac-cm` carries all five `p, role:app-operator` lines plus
`g, app-operator, role:app-operator`; `argocd-repo-risingwave-pipeline` holds a real
`-----BEGIN OPENSSH PRIVATE KEY-----`. Deploy key `argocd-op-usxpress-prod` (id 162114773,
read-only) added to `variant-inc/risingwave-pipeline`, beside the QA one from 2026-08-20.

**Still open:** tenant-wide admin consent — the ONLY thing now blocking Pujit — and adding
Idris to `usx-cloud-admin` if he is meant to be an admin. `role:app-operator` remains
unexercised until a real person signs in; that sign-in is INFRA-1639's acceptance test.
