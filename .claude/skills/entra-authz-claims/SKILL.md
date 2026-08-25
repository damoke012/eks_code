---
name: entra-authz-claims
description: An Entra SSO login succeeds but the user lands with no permissions — an empty Argo CD Applications view, a Grafana Viewer-only session, "SSO is broken" that is actually authorisation. Covers the USX tenant's refusal to emit a groups claim and the app-role route that works instead. Use for any on-prem or cloud app whose role mapping keys on a token claim.
---

# /entra-authz-claims

**A successful login that grants nothing is an authorisation bug, not an authentication bug.**
They look identical to the user: the same login page, the same MFA, the same redirect, and
then an empty screen. Every hour spent on the OIDC config after the token is valid is wasted.

Built from INFRA-1639 on `op-usxpress-dev`, 2026-08-25.

## First: split authentication from authorisation

Do this before touching any config. If the token is valid, nothing about the OIDC
configuration is at fault, and the answer is in the claims or in `policy.csv`.

```
scripts/argocd-token-claims.sh op-dev        # takes a cluster argument
```

A token whose `iat` predates the running `argocd-server` pod tests the **previous** config.
The script labels each one `PREDATES` or `CURRENT`. Three separate runs were wasted on this.

## The USX tenant will not emit a `groups` claim

Established 2026-08-25 for app `Argo CD On-Prem`
(`42dc0c33-4c56-47a5-b207-d119272997aa`), tenant `bbb5a66d-5c9f-482a-969a-a40304b6bc8d`.
**Do not spend time re-deriving this.** Ruled out by readback, not assumption:

| Tried | Result |
|---|---|
| `groupMembershipClaims: SecurityGroup` | no claim |
| `groupMembershipClaims: ApplicationGroup` | no claim |
| `groups` in `optionalClaims.idToken` | present, and still no claim |
| `emit_as_roles` in `additionalProperties` | **not set** — `[]` |
| claims-mapping policy on the SP | none |
| group overage (`_claim_names`) | no — user is in 42 groups |
| removing `requestedIDTokenClaims` | no change |

Cause unknown; it is above cluster visibility. `wip/onprem-argocd/to-questionnaire-entra-groups-claim.md`
is the ask for whoever owns the directory.

## Use app roles instead

`roles` is issued from **appRoleAssignments on the service principal**, a different path
from directory group membership, so whatever suppresses group claims does not touch it. It
is entirely inside an app registration you own — no directory-team dependency.

```
scripts/entra-argocd-app-roles.sh --inspect
scripts/entra-argocd-app-roles.sh --define
scripts/entra-argocd-app-roles.sh --assign platform-admin <group-or-user-objectId>
```

Then rekey the consumer's policy. For Argo CD, both halves in one edit:

```
scripts/pr-argocd-rbac-app-viewer.sh --role-value app-viewer
```

**Group-to-app-role assignment works on this tenant.** No Entra ID P1 obstacle was
encountered — `usx-cloud-admin` holds `platform-admin` directly. Grant teams as groups;
per-user assignment is only a fallback for proving the claim arrives.

## The four rules that cost us the day

1. **A claim NAME is not its value.** `roles` in a claim list proves the claim was emitted.
   `policy.csv` matches on the contents. Print values.
2. **Subjects must all be the same KIND.** A `policy.csv` holding both a group object ID and
   an app-role value has one subject that can never match, and the file does not show which.
   `scripts/verify-argocd-rbac.sh <cluster>` refuses a mixed policy.
3. **`scopes` must name the claim the subjects live in.** App-role subjects under
   `scopes: "[groups]"` is a policy that cannot match. Use `"[roles, groups]"`.
4. **A granted role with no `p,` rules grants nothing** — and presents as a broken login.

## Verify the value, never the sync

A green Kustomization proves the manifest applied. It says nothing about what
`argocd-rbac-cm` holds or whether the subject can match.

```
scripts/verify-argocd-rbac.sh op-dev
```

Argo reloads `argocd-rbac-cm` without restarting, so an `argocd-server` pod older than the
ConfigMap is expected and is not evidence the change failed.

**The only proof is a human signing out and back in.** Zero Applications makes the Argo UI
useless as an RBAC test — an admin and an unauthorised user see the same empty screen — so
test against a cluster that has Applications, and prefer a *second* person to yourself: your
own session may hold permissions from a previous grant.

## Before rekeying an admin subject

Rekeying `role:admin` changes your own access. Merge one cluster at a time, and know the
escape hatch first — the local `admin` account is unaffected by any of this:

```
kubectl --kubeconfig ~/.kube/op-usxpress-dev-fresh.yaml --context admin@op-usxpress-dev \
  -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```
