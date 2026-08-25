# Closing INFRA-1639 and INFRA-1663 — 2026-08-25

**The split proposed earlier today is withdrawn.** It was the right call at 14:00, when
authorisation was blocked on a tenant behaviour owned by another team with no date.
It isn't now: authorisation works, and INFRA-1639 can close as written. Splitting a ticket
to make a blocker somebody else's is only honest while it *is* somebody else's.

One new ticket is still warranted, but it is a question, not a blocker.

---

## INFRA-1639 — Argo CD SSO for application teams → **CLOSE**

> Argo CD on all three on-prem clusters authenticates against Entra ID directly and
> authorises from the token. Dex is removed.
>
> **Authentication.** Confidential (web) client `Argo CD On-Prem`
> (`42dc0c33-4c56-47a5-b207-d119272997aa`), federated through ADFS. All three callbacks
> registered on one registration, so no per-cluster Entra work is needed.
>
> **Authorisation — via the `roles` claim, not `groups`.** Entra will not emit a `groups`
> claim for this application under any configuration tried (`SecurityGroup`,
> `ApplicationGroup`, `groups` in `optionalClaims.idToken`, no claims-mapping policy, 42
> groups so no overage, `emit_as_roles` not set). Cause unknown and tracked separately —
> it is a tenant question, not a blocker.
>
> `roles` is issued from appRoleAssignments on the service principal instead, a different
> issuance path, entirely inside the registration we own. Proven on op-dev at 19:18:27Z:
> `roles → platform-admin`, with a free negative control six minutes earlier — a user
> holding only default access received no `roles` claim at all. Same app, same tenant,
> same federation; the assignment is the only variable.
>
> Group-to-app-role assignment works on this tenant, so teams are granted as groups with
> no per-person administration and no additional licence.
>
> **Roles.** `platform-admin` → `role:admin`. `app-viewer` → `role:app-viewer`, scoped to
> the `apps` AppProject: `get` on applications and logs, `sync` on dev and QA, **no sync
> on prod** — promotion there stays human-initiated by the platform, by design.
> `policy.default` is `""`: authenticating alone grants nothing.
>
> **Merged:** #132, #133, #134 (op-dev) · #135, #136, #139 (op-qa) · #141, #142 (op-prod)
> · #138 (op-dev app-viewer).
>
> **Evidence:** `scripts/close-argocd-sso.sh <cluster>` for each of the three, plus a
> browser sign-in by a platform admin and by an application-team member.
>
> Write-up: `wip/onprem-argocd/FINDINGS-2026-08-25-entra-oidc.md`.
> Procedure: `.claude/skills/entra-authz-claims/SKILL.md`.

**Do not close until an application-team member has signed in.** Everything else is our
own admin access, and the ticket is about theirs. Idris holds `app-viewer`
(`86486897-edd4-537d-b04f-805d6aeff583`).

---

## INFRA-1663 — op-prod ingress → **CLOSE**

> Production could not terminate HTTPS for any of its own hostnames from the day the
> cluster came up until 2026-08-25 — 27 days. It went unnoticed because prod served no
> routes, so nothing ever asked it to.
>
> **Four faults in series, each hiding the next:**
> 1. `istio-ingress/shared-http` served `*.op-qa.usxpress.io` — a byte copy of QA's Gateway.
> 2. The wildcard Certificate was also named for QA and had been failing to issue for 27 days.
> 3. cert-manager had no IRSA credentials. Its ServiceAccount annotation was correct, but
>    injection happens at **pod creation** and that pod predated both the annotation and the
>    webhook, so the SDK fell back to EC2 IMDS — which does not exist on bare-metal Talos.
> 4. The ACME solver's `dnsZones` selector matched only `op-qa.usxpress.io`, so an Order for
>    `*.op-prod.usxpress.io` matched **no solver** and cert-manager created **zero** Challenges.
>
> Fixes: #137 (Gateway + Certificate), a `rollout restart` for the IRSA injection, #140
> (solver zone). `wildcard-op-prod` then issued against the CertificateRequest that had
> been retrying since #137.
>
> Also recovered: the op-prod kubeconfig, rebuilt from its talosconfig
> (`scripts/onprem-prod-kubeconfig.sh`). 13 nodes verified.
>
> **`argocd.op-prod.usxpress.io` is the first DNS record external-dns has ever published
> on op-prod** — the surrounding log is 27 days of "All records are already up to date".
>
> Leftover to clear: the dead `wildcard-op-qa` Certificate and `wildcard-op-qa-k96jn`
> secret in `istio-ingress` on op-prod, which can never issue there and retry forever.

---

## NEW — Entra emits no `groups` claim for `Argo CD On-Prem`

**Not a blocker.** Argo CD is authorised from `roles` and is in production on all three
clusters. This is open because the cause is unknown, and because the answer decides
whether app roles become the house standard for application authorisation or stay a local
workaround.

The specific, reproducible fact for the identity team: on one app registration in tenant
`bbb5a66d-5c9f-482a-969a-a40304b6bc8d`, `groups` is requested in the ordinary way and
never emitted, while `roles` is emitted in the same token to the same user at the same
time. Everything configurable on the application side has been set and read back.

Questions and the full ruled-out table:
`wip/onprem-argocd/to-questionnaire-entra-groups-claim.md`. Question 1 is the control we
lack — whether the cloud EKS fleet's `Argo CD` registration
(`56078536-f4a3-4f92-810e-5106787019a8`) receives a groups claim today. If it does not,
group claims have never worked in this tenant and whatever that app does instead is the
house pattern.

---

## Also worth filing from today

* **op-prod's `letsencrypt-staging.yaml` comment** now reads "restrict this issuer to the
  on-prem **dev** subzone" above an **op-prod** zone. Prose copied dev → QA → prod. Cosmetic;
  a comment does not select a zone.
* **QA had never had a browser sign-in** before today — it was verified by `curl` against
  `/api/v1/settings`, which proves the config is served, not that a human can get in.
