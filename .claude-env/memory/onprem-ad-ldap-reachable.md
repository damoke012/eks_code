---
name: onprem-ad-ldap-reachable
description: "Corp AD is reachable from op-usxpress-dev pods — CoreDNS forwards usxpress.com, 636 LDAPS open; makes a fully-IaC Dex LDAP connector viable with no console step"
metadata:
  type: project
---

**Verified 2026-08-24 from inside the `argocd` namespace on op-usxpress-dev**, by exec-ing
into the already-running `argocd-repo-server` (not a throwaway pod — PodSecurity
`restricted` is enforced there and refused one):

```
getent hosts usxd1vmdc1.usxpress.com      -> 10.10.90.9      # CoreDNS forwards the corp zone
/dev/tcp/usxd1vmdc1.usxpress.com/389      -> OPEN
/dev/tcp/usxd1vmdc1.usxpress.com/636      -> LDAPS OPEN
```

Five domain controllers advertised via `_ldap._tcp.usxpress.com`: `usxd1vmdc1/2/3`,
`usxd2vmdc1/2`, all port 389. `usxpress.io` has no SRV records — the AD domain is
`usxpress.com`.

**Why this matters:** a Dex **LDAP connector** needs no IdP application at all, so it has
**no console step** — unlike Identity Center, where creating the SAML app, its ACS URL,
audience and attribute mappings are all console-only (see
[[argocd-sso-blocked-on-management-account]]). LDAP is a bind DN, a password and search
filters, entirely in the HelmRelease, with the password via ExternalSecret exactly as
`admin.password` already is. It copies to QA and prod as a file.

**Corrected belief:** LDAP was first framed as "a second access model next to Identity
Center." It is not — Identity Center's groups are **synced from this same AD**, which is why
they are named `usx-*`. LDAP reaches the same directory directly instead of through a
federation layer, so `usx-cloud-admin` should return under the same name and `configs.rbac`
needs no change either way.

**Open before it can be used:** an AD **service account** (bind DN + password) that someone
who owns AD must create; and confirming AD group membership returns `usx-cloud-admin` as a
readable name once a bind exists. Use **636**, not 389 — a bind on 389 sends the service
account password in the clear.
