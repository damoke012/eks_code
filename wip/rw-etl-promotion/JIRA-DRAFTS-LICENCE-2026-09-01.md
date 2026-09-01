# INFRA ticket drafts — RisingWave Console licence (relates to INFRA-1674)

Two tickets. The optional "stop the crashloop" ticket was folded into #1 as a decision
point rather than filed — it only becomes work if the licence runs long.

---

## Ticket 1 — Obtain a valid RisingWave Console licence key

**Type:** Task · **Relates to:** INFRA-1674 · **Owner:** Steve → Zach

### What to build

A valid RisingWave Console licence key in hand, so the console can be started on the
on-prem clusters. Today `console_license_key` holds the literal placeholder
`PLACEHOLDER_INJECT_REAL_LICENSE` in **both** `op-usxpress-qa` (527101283767) and
`op-usxpress-prod` (937464026810). The prod console refuses to start:

    license verification failed: license must be a compact JWT

The licence is recorded as lapsed. This is a vendor/commercial dependency with no
engineering work in it, tracked here so it is visible rather than living in a chat thread.

### Acceptance criteria

- [ ] A compact JWT licence key is available (three dot-separated parts, `eyJ` prefix)
- [ ] Its tier and expiry are recorded on this ticket
- [ ] It is confirmed whether ONE key covers dev, QA and prod, or whether each cluster
      needs its own
- [ ] RisingWave's **free-tier** licence has been asked about as a fast path — the console
      appears to require a well-formed licence, not necessarily a paid one
- [ ] **Decision point:** if this will take more than two weeks, raise a follow-up to scale
      the prod console to zero, so prod does not carry two permanently red workloads

### Blocked by

None (can start immediately).

---

## Ticket 2 — Inject the licence and verify the console actually runs

**Type:** Task · **Relates to:** INFRA-1674 · **Owner:** platform

### What to build

The RisingWave Console running on op-usxpress-prod, and QA's console state confirmed
rather than assumed. Injecting the key is three steps, and the middle one is the one that
gets missed.

Terraform creates `console_license_key` with `ignore_changes`, so the real value is
written **by hand** into Secrets Manager and will not be reverted by a later apply.

Then the console pod must be **recreated, not restarted in place**: the value reaches the
container as an environment variable resolved at pod creation, so a crashlooping container
replays the old value indefinitely however green the Secret and ExternalSecret look.

Finally the `rw-bootstrap-service-accounts` Job needs recreating. It currently completes
every group, user and grant successfully and then crashloops on its last step,
`relation "anclax.users" does not exist` — the console's own schema, which only exists
once the console has started. It is a downstream victim of the licence, not a separate
fault.

### Acceptance criteria

- [ ] Real licence written to `op-usxpress-prod/risingwave/console_license_key` and
      `op-usxpress-qa/risingwave/console_license_key`, both as
      `{"RW_LICENSE_KEY": "<jwt>"}`, us-east-2
- [ ] The value is read back and confirmed to be a compact JWT — a `SecretSynced`
      ExternalSecret is NOT evidence the content is valid
- [ ] `risingwave-console` is 2/2 Running on op-usxpress-prod
- [ ] `rw-bootstrap-service-accounts` reaches Completed
- [ ] QA's console state is confirmed (it was unverified on 2026-09-01 — op-qa was
      unreachable) and fixed if it is failing the same way
- [ ] `bash scripts/rw-prod-status.sh` gate 5 passes against a real licence
- [ ] An operator can log in to `risingwave-dashboard.op-prod.usxpress.io` through Entra —
      prod's redirect URI was added to registration `e112d6ce-…` on 2026-09-01

### Blocked by

Ticket 1.
