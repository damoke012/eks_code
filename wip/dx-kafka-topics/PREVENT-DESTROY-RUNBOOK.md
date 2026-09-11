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

**Not** a project variable — Project Variables holds only `topics:<domain>:<name>:<fmt>:*`
entries (partitions and config, scoped per environment). `tf:prevent_destroy` lives in a
**Library Variable Set**: Octopus → project → *Variable Sets*, or *All Variables* to see the
merged view.

⚠️ **Our scripts cannot find it, and both return empty — that is a tooling gap, not absence.**
Verified 2026-09-11: `octopus-project-state.py` enumerates only the project's own variable set
(`variableset-Projects-4801`) and `octopus-release-snapshot-vars.py` prints only unencrypted
project variables. Neither walks Library Variable Sets. An empty result from either says
nothing about whether `tf:prevent_destroy` exists — see [[proxy-is-not-the-property]].

**Use the UI:** Octopus -> project -> **All Variables** (the merged view), search
`prevent_destroy`. It names the owning set and shows the block.

TODO for the tooling: teach `octopus-project-state.py` to follow
`project.IncludedLibraryVariableSetIds` and print those sets too. Until then an empty grep
here is meaningless.

## If it genuinely has to come down

1. **Copy the current value verbatim first.** It is a whole `lifecycle { ... }` block — it may
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
