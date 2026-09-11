# Lowering the topic/user destroy guard on `ix-kafka-topics-users` — and putting it back

Written 2026-09-11 during the failed 1.8.36 production deploy. Not used: the team cut a
revert instead, which was the better call. Kept so the next person does not re-derive it
under time pressure.

## What the guard is

`deploy/terraform/topics.tf:9` and `deploy/terraform/users.tf:35` both contain the literal
line `#{tf:prevent_destroy}` — an **Octopus substitution token**, not committed Terraform.
The whole `lifecycle { ... }` block is injected by Octopus before `tofu` runs.

⚠️ **One variable governs BOTH topics and service users.** Lowering it for a topic deletion
also opens service-account deletion for that run, including `users/risingwave.yml`.

⚠️ `prevent_destroy` sits in a `lifecycle` block on a `for_each` resource, and lifecycle
values cannot reference `each.key`. **There is no way to exempt one topic.** Off means off
for all ~130 production topics for that apply.

## Where the variable is

**A PROJECT variable on `ix-kafka-topics-users`**, scoped to **production**:

    tf:prevent_destroy  =  lifecycle { prevent_destroy = true }     [scope: production]

Confirmed in the UI 2026-09-11 (All Variables, name filter `prevent`, Source column =
`ix-kafka-topics-users`). Scoped to production only, so non-prod deploys already run without
the guard.

❌ **Corrected in place:** an earlier version of this note said it lived in a Library Variable
Set. Wrong. That came from two of our scripts returning empty, which I read as "not a project
variable" when it only meant "our scripts do not show it" — the exact inversion
[[proxy-is-not-the-property]] warns about, made twice in one evening.

⚠️ **Our scripts cannot see it.** `octopus-project-state.py` truncates and
`octopus-release-snapshot-vars.py` returned nothing for it — the second is unexplained and
worth a look (it may mean the variable postdates the 1.8.36 snapshot, which would matter).
Until then, **use the UI**: project -> All Variables -> filter by name. One click, and the
Source column answers the ownership question directly.

TODO for the tooling: make `octopus-project-state.py` filterable rather than head-truncated,
and find out why the snapshot script misses this variable.

## If it genuinely has to come down

1. **Copy the current value verbatim first.** Here it is exactly `lifecycle { prevent_destroy = true }` with nothing else in the block, so flipping the one word is safe — but check, because a block carrying `ignore_changes` would be silently dropped by blanking it.
   carry `ignore_changes` or more. **Do not blank it**; change only the one word, or you will
   silently drop the rest and produce spurious diffs in a production plan.
2. Change `true` -> `false` in the Library Variable Set.
3. **Refresh the release's variable snapshot, or cut a new release.** A release freezes its
   variables at creation; changing the variable does NOT reach an existing release. Without
   this the re-run fails identically and looks like the change did nothing.
   See [[octopus-release-freezes-variables]] and
   `scripts/octopus-release-snapshot-vars.py <project> <version> --apply`.
4. **Freeze master.** This project's process is Step 1 manual-intervention gate, then Step 2
   plan-and-apply in **one script** — nobody sees the plan between plan and apply. Anything
   merged in the meantime deploys unguarded and unseen.
5. Deploy. Then read the task log and confirm the destroy count is what you expected:
   `python3 scripts/octopus-task-log.py ix-kafka-topics-users <version> production --full`
6. **Put it back the same day**, and refresh the snapshot again.

## The better option, nearly always

Revert whatever introduced the destroy, ship everything else, and handle the deletion as its
own reviewed change. On 2026-09-11 one unrelated topic deletion sitting on master blocked an
unrelated team's release, because everyone cuts releases from the same master. Reverting cost
one line and deleted nothing.

Before any topic actually goes: **check consumer groups on it in Confluent.** Deleting a topic
is the only step here that no later release can undo.

## Proven

- `Error: Resource instance cannot be destroyed` on 1.8.36 = `prevent_destroy`, not an outage.
  Plan was `5 to add, 2 to change, 1 to destroy`; the destroy was
  `confluent_kafka_topic.topics["usx_driver_management_netradyne_users_json"]` on cluster
  `lkc-j8n7j8`. Nothing was applied — the guard aborts the whole run, so the five new topics
  did not land either.
- Retrying a failed release is always identical: a release is frozen at its commit AND its
  variable snapshot.

## Tested and killed

- ❌ "`prevent_destroy` can't come from a variable, so it needs a PR." Wrong — true of
  *Terraform* variables, but Octopus does **text substitution** before tofu runs, so the
  literal is produced by Octopus. It is a variable change, no PR.
- ❌ "`sed -i 's/prevent_destroy = true/.../'`" matches nothing: the file contains only the
  token, and `terraform fmt` aligns `=` anyway.
- ❌ Tofu's own suggested `-exclude="confluent_kafka_topic.topics"` excludes **every** topic,
  so the new topics would silently not be created and the deploy would still go green.

## Traps

- One variable, two resources (topics *and* users).
- No per-instance exemption is possible on a `for_each` lifecycle block.
- The manual-intervention gate is **before** the plan, so approving it is not plan review.
- A changed variable does not reach an existing release.
