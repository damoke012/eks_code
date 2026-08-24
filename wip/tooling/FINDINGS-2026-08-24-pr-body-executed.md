# 2026-08-24 — a PR-authoring script executed the code it was describing

**Scope: `scripts/pr-1661-apiserver-webhook.sh --push`, run on WSL against
`variant-inc/iaac-talos`, 2026-08-24. PR #61 was created; its body is corrupt.**

## What happened

The PR body was a double-quoted shell argument:

```sh
gh pr create ... --body "…| \`octopus/apply-bootstrap-perms.sh\` | **Widens an IAM policy** …"
```

Most of the body escaped its backticks. **The disclosure table did not.** In a
double-quoted string a bare backtick opens command substitution, so the shell ran the
contents of every table cell as a command before `gh` was ever invoked:

```
line 161: deploy.ps1: command not found
line 161: .github/workflows/onboard-app.yaml: Permission denied
BENTO_PASSWORD not set - the export/import password must come from a secret, never from the repo
Unable to locate credentials. You can configure credentials by running "aws login".
line 161: CLUSTER_NAME: unbound variable
```

Read that list again. Two of those are the repo's own executables:

- **`octopus/bento-import.py` ran.** It exited on its own missing-`BENTO_PASSWORD` guard —
  the guard added *by the very diff the PR was disclosing*. Had the checkout been `master`,
  that version still carries the hardcoded `BENTO_PASSWORD = "OnPremBentoExport2026"` and
  would have talked to `https://octopus.usxpress.io` unprompted.
- **`octopus/apply-bootstrap-perms.sh` ran.** It calls `aws iam put-role-policy`. It got as
  far as `aws sts get-caller-identity` and died there because the shell's default AWS profile
  has no credentials, then again on `CLUSTER_NAME` being unbound.

**Nothing was mutated. The only reason is that the credentials were absent.** That is luck,
not a control. The same command in a shell with a default profile — or on a machine where
`AWS_PROFILE` happened to be exported — reaches `put-role-policy` against whatever account
that profile points at.

## Why the existing guards did not catch it

`.claude/hooks/guard-mutations.sh` inspects the command *I* issue. The command I issued was
`gh pr create`, which is not a mutation and is correctly allowed. The `aws iam put-role-policy`
was reached by the shell expanding an argument to that allowed command, several layers below
anything a hook can see. **A guard that reads the command text cannot see what the shell will
construct from it.**

Note also which way the danger ran: the risk was not in the change being reviewed, it was in
the *prose about* the change. The more carefully the body documented dangerous content —
naming the IAM widening, quoting the role ARNs, listing the scripts — the more dangerous the
body became. Thoroughness in the description was the attack surface.

## The fix

The body is now `scripts/pr-1661-body.md`, passed as `--body-file`. Prose never transits a
shell string. Plus a fail-closed check that three literals survived verbatim:

```sh
for lit in 'role/*-${CLUSTER_NAME}-*' '`deploy.ps1`' '`BENTO_PASSWORD`'; do
  grep -qF -- "$lit" "$BODYFILE" || { echo "!! PR body lost '$lit'"; exit 1; }
done
```

That check is the part worth copying. The corruption was **silent**: `gh pr create` succeeded,
printed a URL, and reported nothing wrong. The body simply had holes where the identifiers had
been — including, precisely, the row disclosing the IAM widening. Had nobody read the terminal
scrollback, the outcome would have been a merged PR whose reviewer never saw the one item that
needed a deliberate yes.

## Applies to every other script here

Any `--body "…"`, `--description "…"`, `-m "…"` or `--comment "…"` carrying prose about code
has this defect. Backticks are *normal* in a PR body — every inline code span is one.

`scripts/lint-shell-prose.sh` now sweeps `scripts/` for it.

---

**Proven:** on 2026-08-24 `gh pr create --body "<markdown with bare backticks>"` executed
`octopus/bento-import.py` and `octopus/apply-bootstrap-perms.sh` from the checked-out
`iaac-talos` tree; PR variant-inc/iaac-talos#61 was created with a body whose code spans had
been replaced by command output; `gh` reported success.
**Tested and killed:** "escaping the backticks I noticed is enough" — the body escaped ~30 of
them and missed 8, and missing one is sufficient; "guard-mutations.sh covers this" — it
inspects the issued command, and the issued command was `gh pr create`.
**Traps:** a partially-escaped double-quoted string looks correct in review because most of it
is escaped; corruption is silent, `gh` exits 0; the richer the disclosure, the worse the blast
radius; an absent AWS credential is what stopped this, and credentials are usually present.
