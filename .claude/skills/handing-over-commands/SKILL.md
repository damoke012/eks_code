---
name: handing-over-commands
description: Write a shell command for Doke to paste on WSL — before handing over any runnable block, and when a handed-over command fails for a reason unrelated to the task ("command not found", a truncated paste, a shell stranded at a > prompt, a closed shell, "No commits between main and main", a guard that fired on a missing binary or aborted a correct change). Nine measured failure modes, each with the positive form, plus the display artefact that imitates two of them.
---

# Handing over commands

Doke runs the commands; this session cannot reach the clusters, the corp repos or Octopus.
Every command is therefore a **handover**, and a handover fails in ways the command itself
never would.

Nine modes, measured on 2026-10-08 and 2026-10-09, all in work whose own notes warn
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

⚠️ **Recurred 2026-10-20.** A *measured value quoted back to the reader* —
`sg-0c8f8db29b16a1477   allow TCP 0-65535 from 10.16.0.0/20 only` — was put in a bash
fence because it looked like command output. It was pasted and ran:
`sg-0c8f8db29b16a1477: command not found`. A finding is prose however much it looks like
a terminal line. Only lines meant to be executed go in the fence.

## 6. A guard is a measurement, and it can measure the wrong thing

```bash
N=$(git status --porcelain | wc -l)
[ "$N" = "8" ] || echo "ABORT - expected 8 new files"     # aborts on a CORRECT 8-file add
```

`git status --porcelain` **collapses an untracked directory into one line**, so eight
new files under a new directory report as `?? deploy/chart/` — one line. The guard aborted a
good change, and the follow-on `gh pr create` then failed with `No commits between`, which
reads like a branch problem and is not.

Use `--porcelain -uall` to list each file, and assert the *shape* as well as the count:

```bash
N=$(git status --porcelain -uall | wc -l)
O=$(git status --porcelain -uall | grep -vc ' deploy/chart/')
[ "$N" = "8" ] && [ "$O" = "0" ] || echo "ABORT - unexpected file set"
```

The general rule: **a guard that fails has two possible causes — the thing it watches, or
itself.** Print the measurement next to the threshold (`files=$N (want 8)`) so the two are
distinguishable without another round trip. A guard whose output is only ABORT cannot be
debugged remotely.

## 7. A long prose body truncates mid-heredoc and strands the shell

A ~40-line markdown PR body inside `<<'BODY'` truncated on paste. The heredoc never
terminated, so the shell sat at a `>` continuation prompt with the subshell unclosed —
nothing ran, and the next pasted block was eaten as heredoc content. This is mode 5 again,
by volume rather than by backticks: quoting the heredoc makes it *safe*, not *short*.

**Keep a handed-over body under ~20 lines.** For anything longer, build it in its own block
with repeated appends, then pass the file:

```bash
( B=/tmp/pr-body.md; : > "$B"
  echo 'First line.' >> "$B"
  echo '' >> "$B"
  echo 'Second paragraph.' >> "$B"
  echo "  body lines: $(wc -l < "$B")" )
```

Each line is independently short, a truncated paste loses only the tail, and the line count
is a cheap check that the whole thing arrived. Then `gh pr create --body-file "$B"` in a
separate block, guarded on `[ -s "$B" ]`.

## 8. Two shells are in play, and a block will be pasted into the wrong one

Fixing WSL networking means some commands run in **PowerShell on Windows** and some in
**bash inside WSL**. A bash block sent immediately after a PowerShell instruction was pasted
into PowerShell, which parsed `( F=/mnt/...` as an expression, threw six parser errors, ran
one stray `echo "ABORT - ..."` out of context, and then sat at an `InputObject:` prompt
waiting for input — the same stranded-shell state as mode 7, from a different cause.

Worse, the stray line that *did* execute printed an ABORT message, so the transcript contains
a confident failure report that no check produced.

**Say the shell in the sentence before every block, every time** — not once at the top of the
message. And prefer blocks that are *syntactically invalid* in the other shell, so a
misdirected paste fails loudly instead of half-running:

* bash → wrap in `( … )`, which PowerShell rejects immediately.
* PowerShell → use a `Cmdlet-Verb` first token, which bash reports as `command not found`.

Never interleave them. Give all the PowerShell, let it finish, then give the bash.

**A block written for someone else will be run by Doke first.** On 2026-10-20 a
`Test-NetConnection` line was written for an office colleague to run in Windows PowerShell,
labelled as such. Doke pasted it into his WSL prompt **twice**, both times getting
`Test-NetConnection: command not found` — because he is the one driving, and he tests before
he forwards. Labelling the shell is not enough when the audience is a third party.

**Hand over both twins at once.** The colleague's PowerShell line *and* the bash equivalent
Doke can run himself, each labelled, so there is nothing to translate:

```
timeout 5 bash -c 'cat < /dev/null > /dev/tcp/10.10.82.21/443' && echo OPEN || echo BLOCKED
```


**`wsl --shutdown` cannot run inside the WSL it is shutting down** — it is a Windows binary.
Writing `%USERPROFILE%\.wslconfig` is doable from either side (`/mnt/c/Users/<user>/.wslconfig`
from bash), but when the operator is already at a PowerShell prompt, keep everything there:

```
Set-Content -Path "$env:USERPROFILE\.wslconfig" -Value "[wsl2]`nnetworkingMode=mirrored"
Get-Content "$env:USERPROFILE\.wslconfig"
wsl --shutdown
```

## 9. An empty variable in a flag silently selects the default target

```bash
C=$(kubectl config get-contexts -o name | grep -i 'dev' | head -1)
kubectl --context "$C" -n app-risingwave get cm etl-pipeline-image    # C is EMPTY
```

`grep` matched nothing, so `--context ""` fell through to the **current** context and four
queries meant for on-prem dev ran against **qa-one EKS**. The output,
`namespaces "app-risingwave" not found`, reads as a finding about dev. Measured 2026-10-09,
inside a block whose own purpose was to pin the environment — CLAUDE.md rule 2.

An empty string is not an error to `--context`, `--profile`, `--namespace` or `-var`. It
silently selects the default target, which on this box is whichever cluster was last used.

**Derive, then assert, then use — and let the discovery pick nothing rather than guess:**

```bash
( K=$HOME/.kube/op-usxpress-dev-fresh.yaml
  if [ ! -f "$K" ]; then
    echo "NOT MEASURED - $K is missing on this box"
  else
    S=$(kubectl --kubeconfig="$K" config view -o jsonpath='{.clusters[*].cluster.server}')
    N=$(echo "$S" | wc -w)
    echo "servers in file: $N -> $S"
    if [ "$N" != "1" ] || ! echo "$S" | grep -q '10.10.82.50:6443'; then
      echo "ABORT - not a single-cluster op-dev file, nothing queried"
    else
      echo "CONFIRMED op-dev"
      # ... the real work, only here
    fi
  fi )
```

Prefer `--kubeconfig <file>` over `--context <name>` for the on-prem clusters: **op-dev and
op-qa are not in the default kubeconfig at all**, so a context name cannot be right. And
never `export KUBECONFIG` in a handover — a failed export leaves the previous value and the
next command runs against the old cluster ([[wsl-kubeconfig-churn]]).

The general form: **a flag's value must be asserted before the flag is used**, and the
assertion names what it expected. One `grep` that matches nothing is otherwise indistinguishable
from a correct answer.

**And a check must name WHICH fault it found.** Measured 2026-10-15: a block
reported `NOT MEASURED - no valid session for op-dev`, so the advice was
`aws sso login --profile op-dev`. The profile did not exist on that box, and a
login can never create one. Three faults had been collapsed into one message:

| Fault | Fix |
|---|---|
| profile not configured | add it to `~/.aws/config`; a login cannot help |
| session expired | `aws sso login --profile <p>` |
| profile resolves to the wrong account | use a different profile |

A `case` with one catch-all arm turns all three into the middle one. Test for
the profile's existence separately:

```bash
if ! aws configure list-profiles 2>/dev/null | grep -qxF "$p"; then
  echo "$p NOT CONFIGURED on this box - a login cannot fix this"
elif ! A=$(aws sts get-caller-identity --profile "$p" --query Account --output text 2>/dev/null); then
  echo "$p session invalid - run: aws sso login --profile $p"
elif [ "$A" != "$WANT" ]; then
  echo "$p is account $A, wanted $WANT - wrong profile for this step"
fi
```

**Better still, do not take the profile's name from me at all.** `op-dev`,
`usx-dev` and a dozen others are equally plausible and only one is real.
Resolve it by the thing that actually identifies the target — the account
number:

```bash
for p in $(aws configure list-profiles 2>/dev/null); do
  A=$(aws sts get-caller-identity --profile "$p" --query Account --output text 2>/dev/null) || true
  [ "$A" = "$WANT" ] && { echo "$p"; break; }
done
```

## ⚠️ Not a mode: the echo scrambles, the bytes do not

Measured 2026-10-15. A pasted block came back in the transcript as:

    fi )--title "feat(promote): promote QA and prod..." --body-file "$B"

The `fi )` had jumped ahead of the line it followed, and a heredoc block echoed with its
closing lines spliced into the middle of the Python. Both look exactly like mode 2 and mode 7.

**They were not.** The commands ran correctly and opened the PR. What interleaves is the
terminal's *echo* of a multi-line paste with the output of the lines already executing — a
display artefact. The bytes arrive intact.

I read the scramble as corruption, announced it to Doke, and rewrote the remaining blocks to
remove every `\` continuation. That work bought nothing, and the message asserting the paste
was corrupting was wrong. The real failure in the same sequence was ordinary: **a block was
skipped**, and its own `NOT MEASURED` guard said so immediately.

**How to tell them apart — never from the echo:**

* Corruption shows up in a **measurement**: a line count that disagrees, `syntax OK` failing,
  a `sha256sum` mismatch, a shell stranded at `>`.
* A scramble shows up only in how the paste *looks*, while every guard passes and the command
  does its job.

So judge the paste by the arrival check, not by reading it back. And note that `wc -l` plus a
syntax check is weaker than it looks for a generated script — a file can keep its line count
and still have lost a block. Count the **structure**: `grep -c 'hits += 1'` against an expected
number is what actually proved the 42-line patch script had all four of its replacements.

This is [[transport-failure-not-a-verdict]] turned around: not a transport failure reported as
a finding about the system, but a *display* artefact reported as a finding about the transport.

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
- [ ] Every guard prints its measurement beside its threshold, so an ABORT can be told apart
      from a broken guard without another round trip.
- [ ] No handed-over heredoc body exceeds ~20 lines; longer prose is built with appends in a
      block of its own and passed with `--body-file`.
- [ ] Every block names its shell in the preceding sentence, and is syntactically invalid in
      the other shell so a misdirected paste fails instead of half-running.
- [ ] A generated script's arrival check counts its **structure** (`grep -c` on a repeated
      marker, against a stated number), not just `wc -l` — a file can keep its line count and
      still have lost a block.
- [ ] A scrambled echo is judged by the guards, never by reading it back. Every guard passing
      means the paste arrived.

## Why this exists

These are not typing mistakes. Each one cost a round trip, and two of them cost an outage of
the operator's own session or terminal. The command was correct every time; the **handover**
was not. Related: [[prose-through-shell-strings]], [[transport-failure-not-a-verdict]],
[[explain-simply-for-delegation]].
