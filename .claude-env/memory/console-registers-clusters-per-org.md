---
name: console-registers-clusters-per-org
description: "RisingWave Console gives every SSO user a private organisation and registers the cluster PER ORGANISATION, so a login succeeds and shows nothing; two separate one-shot jobs each covered only who existed when they fired"
metadata:
  type: project
---

**Measured 2026-10-26 on op-usxpress-dev.** Jenni logged into the Console, authenticated, and
saw no database objects. Not a RisingWave permission — every source and view is owned by
`root`, and the Console reaches the cluster with its own stored credentials, not hers.

`public.cluster_connection_info` is keyed by `org_id`. It held eight rows, orgs 1–8, seven of
them written in one batch at **2026-10-06 19:02** covering every organisation that existed at
that instant. Tim's org was created 17:21 that day and has a cluster. Doke's was 21:43 and
does not. Jenni's was 23 October.

**Two one-shots stacked, each covering only who existed when it fired:**

1. The Console's own seeding on 6 October.
2. `Job/rw-bootstrap-service-accounts`, which already assigned every user to org 1 — and last
   completed **101 days earlier**, around 17 July. That is the day Idris was added to org 1,
   and the reason he is the only person who never hit this.

**Fixed** by PR #59 on `variant-inc/iaac-risingwave-onprem`: the Job became a **CronJob every
15 minutes**, and Idris added a `console_admins` list to the `rw-user-definitions` ConfigMap
so admin comes from Git rather than a hand-typed row. Proven by Pujit — he was in org 7,
nobody touched his row, and the job moved him.

⚠️ **QA and prod still carry the one-shot Job.** The next person who signs into either hits
exactly this.

**Traps found getting here:**

* The Console's live tables are in the **`anclax`** schema. `public` holds a complete, EMPTY
  copy of the same schema, so a query against it answers every question with zero rows and
  looks authoritative. The DSN connects as user `risingwave`, whose `search_path` resolves to
  `anclax`; querying as `postgres` lands in `public`.
* `anclax.org_owners` is unique on **`org_id` alone** — an organisation has exactly ONE owner,
  and the job forces it back to root every run. So "give this person admin" cannot be done by
  adding an owner. The role lives in `public.user_roles` instead, which the job did not manage
  until #59.
* `wget` is not in the console container, so probing it returns empty output that reads
  exactly like a 404.

Related: [[a-proxy-is-not-the-property]], [[adjacent-step-green-signals]].
