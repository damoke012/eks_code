---
name: prose-through-shell-strings
description: "A PR body passed as a double-quoted shell string executes its own backticks — on 2026-08-24 it ran aws iam put-role-policy; pass prose as a file"
metadata:
  type: feedback
---

Never pass prose to a command as a double-quoted shell string. Use `--body-file` / `-F` with a
real file, or a `<<'QUOTED'` heredoc.

On 2026-08-24 `scripts/pr-1661-apiserver-webhook.sh` passed a PR body as `gh pr create --body
"..."`. Most of it escaped its backticks; the disclosure table did not. The shell
command-substituted every table cell, executing `octopus/bento-import.py` and
`octopus/apply-bootstrap-perms.sh` — which calls `aws iam put-role-policy`. It reached
`aws sts get-caller-identity` and died only because the default AWS profile had no
credentials. CloudTrail (us-east-1 — IAM is global, us-east-2 returns empty regardless)
confirmed no `PutRolePolicy`.

**Why:** backticks are *normal* in a PR body — every inline code span is one. So "escape them"
is not the rule; "prose never transits a shell string" is. The corruption was silent: `gh`
exited 0, printed a URL, and the body simply had holes where the identifiers had been —
including the row disclosing an IAM widening. The more carefully the body documented dangerous
content, the more dangerous the body became.

`.claude/hooks/guard-mutations.sh` cannot catch this: the issued command was `gh pr create`,
correctly allowed, and the IAM call was built by the shell from an argument to it.

**How to apply:** write the body to a file, pass `--body-file`, and assert a few literals
survived verbatim before publishing. `bash scripts/lint-shell-prose.sh` sweeps `scripts/` for
the pattern and is section 8 of weekly-maintenance. See
wip/tooling/FINDINGS-2026-08-24-pr-body-executed.md and [[adjacent-step-green-signals]].
