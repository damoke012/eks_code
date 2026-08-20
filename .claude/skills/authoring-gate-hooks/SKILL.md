---
name: authoring-gate-hooks
description: Write or review a hook that BLOCKS an action — a PreToolUse guard, a pre-commit check, an admission policy, a CI gate, anything that decides allow-or-deny. Use when adding a guard, "stop me from running X against prod", "block mutating commands", reviewing an existing hook, or when a check passed and you cannot tell whether it actually ran. Covers the fail-open trap and the four-case test that catches it.
---

# Authoring a hook that gates an action

A gate has two failure directions and they are not equally bad. Blocking something safe is
recoverable in seconds — you see it, you adjust. Allowing something dangerous is discovered
afterwards, if at all. **The failure direction is the whole design.** Everything below follows
from that one asymmetry.

## The boundary first

Before any code, write down four things. If you cannot state them, you are not ready to write
the hook.

| | |
|---|---|
| **What it guards** | the exact resource — an account id, a cluster name, a branch |
| **What must be blocked** | three concrete commands, written out in full |
| **What must pass** | three concrete commands that look similar and must not block |
| **What happens on confusion** | the payload is unreadable, the parser dies, the input is empty |

That fourth row is the one that gets skipped, and it is where guards fail.

## The fail-open trap

The most common bug in a gate is not a wrong pattern. It is a gate that never inspects the
input and reports success anyway:

```bash
cmd=$(printf '%s' "$payload" | python3 -c '...' 2>/dev/null)
[ -z "$cmd" ] && exit 0        # ← every unparseable payload is now ALLOWED
```

`2>/dev/null` hides the parser dying. The empty result is then read as *"nothing to inspect"*
when it actually means *"I could not inspect this."* A malformed payload carrying a real
production mutation sails straight through, and the guard's own test suite stays green,
because its tests all send well-formed input.

**Fail closed instead.** An input you cannot read is not evidence of a safe input:

```bash
cmd=$(printf '%s' "$payload" | python3 -c '...' 2>/dev/null); parse_rc=$?
if [ "$parse_rc" -ne 0 ] || { [ -z "$cmd" ] && [ -n "$payload" ]; }; then
  cmd="$payload"      # scan the RAW input rather than trusting an empty result
fi
[ -z "$cmd" ] && exit 0        # genuinely empty input only
```

## The four-case test — pin these permanently

Two directions is not enough. A gate needs four, and the middle two are the ones nobody writes:

```
1. garbage input, no dangerous content      -> allow   (0)
2. TRUNCATED/malformed input, real mutation -> BLOCK   (2)
3. payload valid but key unexpected/renamed -> BLOCK   (2)
4. control: well-formed, real mutation      -> BLOCK   (2)
```

If 2 or 3 return allow, there is a silent bypass. Case 4 alone will pass regardless, which is
exactly why a suite containing only case 4 is worse than no suite — it retires the suspicion
without earning it.

## Mutation-test the gate itself

Run the suite against the *broken* version, not just the fixed one. A check that cannot go red
proves nothing. If restoring the bug does not turn the suite red, the suite is decorative.

## Traps

- **A green suite is not a working guard.** Verify it is actually *registered* — a hook file
  that exists but is not wired into settings never runs. Check registration in the maintenance
  script, not by memory.
- **Writing is not running.** A guard that pattern-matches command text will block a runbook
  that merely *quotes* a protected command. Strip heredoc bodies before matching, and pin that
  as a test case — otherwise documenting the danger becomes impossible.
- **Test the guard from a file, not inline.** A test command containing the blocked pattern
  gets blocked by the guard you are testing.
- **Narrow and correct beats broad and guessed.** A guard that blocks routine work gets
  disabled, and then it protects nothing. Cover only what you have confirmed, and record what
  is deliberately uncovered.
- **A guard covering 1 of 8 targets is not 12% safe** — it is fully unsafe for the other 7,
  while *feeling* protected. Say which are uncovered, out loud, every time.

## Related

`[[capture-learning]]` — when a gate fails, the fourth question ("could a check have caught
it?") is this skill.

## The inverse: adding a gate to a path that already works

Everything above is about a gate that fails **open** — it passes because it never ran. There is
a mirror failure, and it bites when you *harden* something rather than build it.

A new check added to a working path fails **closed**, and takes the working path with it.

INFRA-1641, 2026-08-20: hardening `ecr-credentials-sync` I added
`aws ecr describe-registry` as a token verification, under `set -e`. `DescribeRegistry` is a
different IAM action from `GetAuthorizationToken`, and the IRSA role does not grant it. As a
hard gate that check would have failed the first run and every run after it, and the cluster
would have lost its image-pull credential within 12 hours — a hardening PR causing the outage
it was written to prevent. It shipped advisory and logged
`WARNING: could not verify the token (ecr:DescribeRegistry may not be granted)` on the very
first run.

**The rule.** A check added to a path that already works starts advisory. It becomes a gate
only once you have seen it pass — on real inputs, with the real identity. State the promotion
condition in the code, so the warning is not permanent by accident:

```bash
# ADVISORY, NOT FATAL, deliberately: <the permission or precondition that is unproven>.
# Grant <X> and this becomes a real gate; until then it is a warning in the log.
```

**And verify by running it, not by merging it.** A CronJob change is not verified by a green
Flux reconcile — that proves the manifest applied. Trigger one run and read the log:

```bash
kubectl -n <ns> create job --from=cronjob/<name> <name>-verify-<ticket>
kubectl -n <ns> logs job/<name>-verify-<ticket>
kubectl -n <ns> delete job <name>-verify-<ticket>
```

Otherwise the next run is at 06:00 and nobody is watching.