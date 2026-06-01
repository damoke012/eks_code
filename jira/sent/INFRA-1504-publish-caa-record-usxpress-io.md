---
key: INFRA-1504
status: filed
assignee: Doke
reporter: Doke
created: 2026-06-01
filed: 2026-06-01
initiative: onprem-networking
parent_link: INFRA-1492
---

# Publish CAA record on usxpress.io + on-prem subzones (LE-pinned)

## Context
Per the 2026-05-29 networking/CySec call, Brendan recommended adding a CAA (Certification Authority Authorization) record to `usxpress.io` and the on-prem subzones to pin Let's Encrypt (and possibly GoDaddy) as the only authorized CAs. CAA is an industry-standard (CA/Browser Forum mandatory since 2017) defense against rogue cert issuance — every compliant CA must check CAA before issuing.

Blocked until Steve Duck confirms the parent zone registrar (likely GoDaddy, possibly migrated under John Quick Griffin's umbrella) — see follow-up coordination in 2026-05-29 call review.

## Scope

**In:**
- Confirm registrar for `usxpress.io` (Steve Duck → John Quick Griffin loop-in).
- Decide CA allowlist: LE only, or LE + GoDaddy + Amazon (for ACM/PCA future flex).
- Decide CAA placement: parent zone only (covers subzones by inheritance), or also explicit at subzone for clarity.
- Publish via registrar console (or Route53 if migration happened).
- Verify via `dig CAA usxpress.io +short` and `dig CAA op-dev.usxpress.io +short`.
- Test that LE renewal still succeeds with CAA in place (it should — LE is in the allowlist).

**Out:**
- DNSSEC enablement (separate concern).
- IODEF reporting endpoint configuration (informational, low priority).
- Changes to existing certs.

## Definition of done
- [ ] `dig CAA usxpress.io +short` returns records pinning approved CAs (e.g., `0 issue letsencrypt.org`, `0 issuewild letsencrypt.org`).
- [ ] LE renewal still succeeds against on-prem cluster after CAA published (smoke test by triggering a renewal).
- [ ] CAA records visible to external lookups (not just internal DNS — confirm via `dig @1.1.1.1` or similar).
- [ ] Documented in `docs/architecture/` or `wip/onprem-networking/` so future engineers know the constraint.

## Suggested approach
Recommended CAA content (LE + Amazon for flex):
```
usxpress.io.  IN CAA 0 issue "letsencrypt.org"
usxpress.io.  IN CAA 0 issue "amazon.com"
usxpress.io.  IN CAA 0 issuewild "letsencrypt.org"
usxpress.io.  IN CAA 0 issuewild "amazon.com"
usxpress.io.  IN CAA 0 iodef "mailto:security@usxpress.com"
```
Adjust based on Brendan's preference on the CA list. If org plans to phase to ACM later, leave `amazon.com` in.

## Constraints
- **Blocked on Steve Duck** for registrar confirmation + John Griffin intro.
- No Octopus access required.
- Coord: Steve Duck (registrar action), Brendan (final CA list), John Griffin (parent-zone owner).

## Links
- Parent umbrella: [INFRA-1492](https://usxpress.atlassian.net/browse/INFRA-1492)
- 2026-05-29 call review: `wip/onprem-networking/networking-call-review-may29.md`
- RFC 8659 (CAA): https://datatracker.ietf.org/doc/html/rfc8659

## Estimate
S — DNS record edit + verification. ~1 hour once registrar access confirmed. Calendar time gated on Duck/Griffin.
