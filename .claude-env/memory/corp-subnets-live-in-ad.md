---
name: corp-subnets-live-in-ad
description: The authoritative USX corporate subnet list is AD Sites and Services, readable by ANY domain user with one PowerShell line — no network-team ticket, no bind account
metadata:
  type: reference
---

Read 2026-10-20 from a domain-joined laptop on the VPN. Windows PowerShell, no special rights,
read-only, no ticket:

```
$s = [ADSI]"LDAP://CN=Subnets,CN=Sites,CN=Configuration,DC=usxpress,DC=com"
$s.Children | ForEach-Object { $_.cn }
```

Add site names with
`$s.Children | Select-Object @{n='Subnet';e={$_.cn}}, @{n='Site';e={$_.siteObject}}`.

**24 subnets, three sites.** `Jenkins` is HQ (Jenkins Rd, Chattanooga) and holds almost
everything; `DR` holds `10.11.32.0/19`, `10.9.0.0/16`, `192.168.222.0/24`; `AzureAD` holds
`10.8.90.0/24`.

| Range | Note |
|---|---|
| `10.10.0.0/16` | HQ — **contains the office Wi-Fi `10.10.72.0/24` AND our on-prem workers `10.10.82.0/24`** |
| `10.11.0.0/19` | the corp VPN pool |
| `172.17.0.0/16` | contains `172.17.13.0/24` (Tim, Sept 2026) |
| `10.6/10.7/10.8/10.100/10.102/10.107/10.110 .0.0/16` | HQ |
| `10.9.0.0/16`, `10.11.32.0/19`, `192.168.222.0/24` | DR |
| twelve `192.168.x.0/24` | HQ |

**Why:** every "what are the office subnets" question is answerable in ten seconds without
the network team. It is the registry they maintain themselves, so it is defensible in a
review in a way that a list assembled from two laptops is not. It also told us immediately
that the office Wi-Fi and our cluster workers share one registered /16.

**How to apply:** use it for any source-CIDR allow-list — it is what
[[office-vlan-blocked-to-onprem]] needed. ⚠️ **It is maintained by hand**, so a newly cut
subnet can be missing; it is "almost certainly complete", not guaranteed. Confirm the final
list with the network team as a yes/no rather than asking them to compile one. The same
directory is reachable over LDAPS from on-prem pods ([[onprem-ad-ldap-reachable]]) if this
ever needs to be automated, though that route needs a bind account and this one does not.
