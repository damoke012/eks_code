# eks_code — the operator's working repo for USX cloud + on-prem platform

Notes, drafts, review records and automation for the EKS fleet and the on-prem Talos
clusters. It is **not** a deployment source: nothing here is applied from here.

## ⛔ Standing rules

1. **Never mutate production from this repo.** No `terraform apply`, no `terraform destroy`,
   no `aws … delete-*/put-*/update-*`, no `kubectl apply|delete|patch` against a prod account
   or cluster. *Drafting the change, the plan and the exact commands is expected* — running
   them is not. `iaac-talos` promotes dev → QA → prod through **Octopus only**; a local apply
   is never the answer. Enforced by `.claude/hooks/guard-mutations.sh`, not just by this line.
2. **Label every command with its environment**, and pin it with the explicit flag —
   `--context`, `--profile`, `-var`. A command that could hit more than one environment is a
   bug even when it works.
3. **No throwaway workloads in a prod cluster.** Never `kubectl run` or `kubectl debug` a test
   pod there. Read telemetry, or exec into a pod that is already running.
4. **A green sync is not a valid value.** An `ExternalSecret` reporting `SecretSynced` proves
   the sync ran, not that the content works. Check the value. This has bitten us twice —
   Wiz, and QA etcd-backup.
5. **An empty grep is not evidence of absence.** Verify the selector and the target resolve
   before concluding something is not there.
6. **No placeholders in runnable commands.** Never hand over `<foo>`, `…`, or an unset `$VAR`.
7. **Never add AI attribution to git.** No "Generated with Claude Code" in PR bodies, no
   `Co-Authored-By` trailers on commits.
8. **Corp GHE is not personal GitHub.** USX and variant-inc repo work happens on WSL against
   corporate GitHub Enterprise. The codespace `damoke012` token must never reach a USX repo.

## Skills (`.claude/skills/`)

| Skill | Reach for it when |
|---|---|
| `capture-learning` | an investigation just concluded — run it before moving on |
| `pr-review-rw` | "review PR #N on `<repo>`", anything touching RisingWave namespaces |
| `prod-auth-triage` | blanket 401s from a prod API, `IDX10214`, `AADSTS500011` |
| `azure-oidc-federation` | `AADSTS700213`, a workflow failing `azure/login` on a new branch |

## The learning loop

When something is figured out, **capture it before moving on** (`capture-learning`). Four
questions: what is now proven, what did we believe that was wrong, **did a procedure change**
(update the skill, not just the note), and **could a check have caught it**.

`bash scripts/kb-lint.sh` catches knowledge that has rotted.
`bash scripts/weekly-maintenance.sh` checks the notes, the skill descriptions, the upstream
skill pin, the guard, and the backup freshness.

## House style for notes

End every note with what was **proven**, what was **tested and killed**, and the **traps**.
Correct earlier wrong claims in place rather than deleting them. Numbers carry a scope and a
timestamp.
