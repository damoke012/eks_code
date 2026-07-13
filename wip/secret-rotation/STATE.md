# Secret rotation — STATE (from call 2026-07-10)

**Goal:** rotate the 11 Entra ID app-reg client secrets expiring Jul–Aug 2026 without a prod auth breakdown. Soonest: `xpm-classic-auth-dx` (prod) 7/17.

## Plan (agreed on call)
1. Steve grants **Parul** Azure access (via Marvel / Azure admin group) — last piece missing; in progress. NO team member has it yet.
2. Test rotation in **DPL → dev → higher envs**. Prod ones done together on a call.
3. Write a **runbook** (this dir: `rotation-runbook-DRAFT.md`) — document steps + gotchas as we learn them.
4. Confirm the possibly-stale apps with owners (cc Steve) BEFORE deleting anything.
5. Rotate the one expiring next week (prod) once dev proves out.
6. Future: automation (Idris) — job scans pods for near-expiry secrets, swaps old→new from SM.

## Key gotchas
- **Terraform state files** must be updated to the new secret, or TF reverts to the old one.
- Confirm each secret's consumption: env var (pipeline handles) vs mounted/uploaded secret.
- Do NOT destroy+recreate apps in prod (only Azure-free option, but downtime) — rejected.
- Rotation is NOT automatic (confirmed).

## App ownership + status tracker
| App | Env | Exp | Deployed in prod? | Owner / contact | Action |
|---|---|---|---|---|---|
| usx-orders-auto-booking-handler | prod | 7/29 | ✅ yes | — | ROTATE |
| usx-missions-event-handler | prod | 8/1 | ✅ yes | — | ROTATE |
| freight-allocation-api | prod | 7/29 | ✅ yes | — | ROTATE |
| xpm-classic-auth-dx | prod | **7/17** | ❌ no namespace | **Buddy** (Garrett left) | Confirm w/ Buddy → likely retire |
| mulesoft-auth-dx | prod | 8/1 | ❌ no deployment | Srikanth / Buddy / Jason | Confirm; maybe already rotated last wk |
| knx-auth-dx ("cadex") | dev/qa/stage/prod | 7/31 | ? | unknown (Steve finding; maybe Buddy) | Identify owner → confirm |
| usx-orders-auto-booking-handler | stage | 7/24 | ? | — | confirm |
| usx-missions-event-handler | stage | 7/24 | ? | — | confirm |

## People
Dean = meeting lead (≈ Dare Oke). Mark = drives rotation, validates lower envs. Rohit Saini = checks cluster namespaces/deployments. Parul = Azure-access recipient / rotator. Steve = grants Azure access, knows app owners. Idris = automation idea. Marvel = Azure admin. Buddy = app owner (inherited Garrett's).
