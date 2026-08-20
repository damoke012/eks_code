---
name: entra-secret-rotation
description: "Active — 11 Entra ID app-reg client secrets expiring Jul–Aug 2026; manual rotation (not automatic), test in DPL→dev→prod, confirm stale apps with owners first"
metadata: 
  node_type: memory
  type: project
  originSessionId: 161fed6b-7af8-49e8-9abf-c06ed6494c28
---

Active (weekend/next-week urgent as of 2026-07-10..13): 11 Entra ID (Azure AD) app-registration **client secrets** (`dx-{env}-usxpress-{app}`) expiring Jul–Aug 2026; soonest `xpm-classic-auth-dx` (prod) 7/17. OAuth client secrets, NOT docker secrets in dpl.

**Access (RESOLVED 2026-07-13):** access adjustments landed Fri 7/10; **Parul now HAS Azure access** (tested Mon morning, works). Idris/Dare should also have better Azure access as of 7/13. (Granted by Steve via Marvel.)

**Progress (2026-07-13 standup):** rotation method **tested in DPL — worked** (rerun job after cleaning up the secret). `xpm-classic-auth-dx` (7/17) **negated** — no longer urgent (stale/handled), buys time on the rest. Next: clean up **2 stage secrets** + redeploy **2 stage apps** today after a ~1hr dev-team announcement window (Rohit posts; Parul not a moderator on DevEx Teams announce channel — Steve to add her). Recent deploy failures triaged as AD-access / McLeod-weekend-update / unrelated — NOT node or our changes.

**Confirmed: rotation is NOT automatic** (checked 2026-07-10 AM). Manual for now; automation is a future process (see Idris's idea below).

**Rotation method (agreed):**
1. Get Azure access → create a NEW client secret in Azure AD.
2. Update the value in **AWS Secrets Manager** (source of truth).
3. **Update the Terraform state files** to point at the new secret — else TF reconciles back to the old one (key gotcha).
4. Cluster side: delete the expiring K8s secret → rerun the pipeline → it pulls the new value from SM into the pod.
5. Confirm WHERE each secret is consumed — env var (pipeline handles it) vs an uploaded/mounted secret the app needs separately.
Do NOT delete Azure credentials casually. Test order: **DPL → dev → higher envs**; do the prod ones together on a call for safety. Write a **runbook/playbook** (Dean's ask) — document steps + gotchas. Future: Idris's on-prem-style job that scans pods for near-expiry secrets, removes old, pulls new from SM automatically.

**App confirmation (focus = the 3 prod-related; 8 still to confirm before any delete):**
- `usx-orders-auto-booking-handler`, `usx-missions-event-handler`, `freight-allocation-api` — deployed in prod → ROTATE, exclude from cleanup.
- `xpm-classic-auth-dx` (prod, exp 7/17): **NOT stale — CORRECTED 2026-07-17.** Buddy needed it (prod incident on its expiry date); it's live/in-use. SM secret `azure-app-dx-prod-usxpress-xpm-classic-auth-dx` exists in prod acct 937464026810 us-east-2 (DeletedDate null, appId `d20d57a9-81d9-4b69-89af-bc8a5fbc06ac`, tenant `bbb5a66d-…`). **KEEP — exclude from cleanup.** ⚠️ Its client secret got printed into a session transcript 2026-07-17 (get-secret-value --output text) → **ROTATE it.** Lesson: it has **NO k8s/ESO consumer** (empty `xpm` ns on prod) yet is live → "no namespace/deployment" is an UNRELIABLE stale signal for out-of-cluster consumers; use Entra sign-in logs, not k8s footprint.
- `mulesoft-auth-dx` (prod, 8/1): **no deployment in ns → likely stale; possibly already rotated last week** (mulesoft incident). Contacts: Srikanth / Buddy / Jason.
- `knx-auth-dx` / "cadex" (dev/qa/stage/prod, 7/31): owner unknown, Steve finding (maybe Buddy).

**Process rule:** message the app OWNER to confirm live/not-live, **cc Steve** (Steve redirects if wrong owner). Get a record of reaching out before deleting anything. Authoritative in-use signal = Entra sign-in logs / namespace+deployment existence, NOT secret expiry. Notes/runbook: `wip/secret-rotation/`. **Filed 2026-07-13: INFRA-1595** (operational rotation + runbook; in sprint 4047 "UI Sprint 1", assignee Parul) + **INFRA-1596** (future automation, backlog). Related: [[user-doke-onprem-platform]].
