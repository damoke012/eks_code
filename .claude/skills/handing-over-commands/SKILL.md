---
name: handing-over-commands
description: Write a shell command for Doke to paste on WSL — before handing over any runnable block, and when a handed-over command fails for a reason unrelated to the task ("command not found", a truncated paste, a closed shell, "No commits between main and main", a guard that fired on a missing binary). Five measured failure modes, each with the positive form.
---

# Handing over commands

Doke runs the commands; this session cannot reach the clusters, the corp repos or Octopus.
Every command is therefore a **handover**, and a handover fails in ways the command itself
never would.

Five modes, all measured on 2026-10-08 in one session, all in work whose own notes warn
about them.

## 1. The shell is interactive — `exit` closes it

```bash
A=$(aws sts get-caller-identity --query Account --output text)
[ "$A" = "155768531003" ] || { echo "ABORT"; exit 1; }     # logs the operator OUT
```

`exit` in a pasted block runs in the login shell. This ended a session mid-measurement and
cost an `aws sso login`.

**Write the guard as `if`/`else` inside a subshell**, so the failure path prints and returns:

```bash
( A=$(aws sts get-caller-identity --query Account --output text 2>&1)
  if [ "$A" != "155768531003" ]; then
    echo "ABORT - wrong account, nothing read"
  else
    ...
  fi )
```

The subshell also contains `cd`, `export` and variables, so a block cannot leave the next one
in a surprising state.

## 2. A long line does not survive the paste

A 1500-character base64 line truncated mid-quote and hung the shell on a `>` continuation
prompt. **Keep every line under ~120 characters.** Many short lines paste reliably; one long
one does not.

Transferring a file is the usual reason a line gets long. **Prefer not to transfer the file**
— give the few commands that do the job directly, or put the file in a repo Doke can clone.
If a payload must cross, chunk it to ~1000 characters per `echo -n … >>` and gate the result
on a `sha256sum` that refuses to extract on mismatch.

## 3. A missing tool is not a failing system

```bash
kustomize build "$D" || echo "ABORT - build broken"     # prints ABORT when kustomize is absent
```

`kustomize`, `dig` and `flux` are **not installed on this WSL box**. The `||` branch cannot
tell exit 127 from a real failure, so it reports a transport failure as a finding about the
system under test — inside a check written to prevent exactly that
([[transport-failure-not-a-verdict]]).

**Test for the binary first, and say NOT MEASURED when it is absent:**

```bash
if ! command -v kustomize >/dev/null 2>&1; then
  echo "NOT MEASURED - kustomize absent, this is not a build failure"
elif kustomize build "$D" > /tmp/out.yaml; then
  echo "BUILD OK"
else
  echo "ABORT - build really is broken"
fi
```

Known present: `kubectl`, `git`, `gh`, `aws`, `az`, `python3`, `curl`, `jq`.
Known absent: `kustomize`, `dig`, `flux`.

## 4. A PR needs a commit, a push, and a branch of its own

`gh pr create` produced `No commits between main and main` twice, from two causes in one
sequence:

* **No `git commit`** — the edit was still in the working tree.
* **`git checkout -B feature origin/main`** sets the branch's upstream to `origin/main`, and
  `gh` resolves the head ref from the upstream. It saw `main`.

**Always `git add` → `git commit` → `git push -u origin <branch>` → `gh pr create`.** The
`-u` on a push to the branch's *own* name is what fixes the head resolution.

**Pin the base.** `iaac-talos-flux-platform` is branch-per-cluster and GitHub offers the wrong
default: `--base op-qa`, never bare. See [[platform-repo-branch-refs-collide]] for the branch
names that are outright impossible there.

## 5. Prose in a fenced block gets pasted into the shell

Quoted output, YAML fragments and expected results reach the terminal as commands
(`host:: command not found`, `2026-10-06T19:05:20: command not found`). A PR body passed as
`--body "…"` once executed its own backticks ([[prose-through-shell-strings]]).

**Put only runnable lines in ```bash fences.** Quote expected output as indented text or a
table, and pass any prose to a tool with `--body-file`, never `--body`.

## Before sending any block

- [ ] Every line under ~120 characters.
- [ ] No `exit`; guards are `if`/`else` inside `( … )`.
- [ ] Every tool it invokes is in the "known present" list, or the block tests for it.
- [ ] No placeholder — no `<foo>`, no `…`, no unset `$VAR`. Self-discovering (`F=$(grep -rl …)`)
      beats asking Doke to substitute. CLAUDE.md rule 6.
- [ ] A failure prints a labelled reason and reads NOT MEASURED, never a finding.
- [ ] Destructive steps and their guard are in **one** block, with the guard inside the
      script — never "check this, then run that".
- [ ] It says what the pass looks like, so a wrong answer is visible without me.

## Why this exists

These are not typing mistakes. Each one cost a round trip, and two of them cost an outage of
the operator's own session or terminal. The command was correct every time; the **handover**
was not. Related: [[prose-through-shell-strings]], [[transport-failure-not-a-verdict]],
[[explain-simply-for-delegation]].
