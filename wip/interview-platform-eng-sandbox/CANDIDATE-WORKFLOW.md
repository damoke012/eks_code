# Candidate Interview Workflow

End-to-end workflow for running a hands-on platform engineer interview against this template.

**Validated**: 2026-06-04 with `damoke012` (test candidate). All 6 Ex 01 tests passed, CLI smoke green, defaults verified.

## Overview

Candidate accesses **their own codespace** spawned from `dare-x/interview-platform-eng-sandbox`. You watch via Teams screen share. Runs on the candidate's free Codespaces tier (60 core-hours/month).

## PRE-INTERVIEW (~10 min before)

### 1. Get the candidate's personal GitHub username

Their PERSONAL account, not employer-tied — Codespaces hours follow the account.

### 2. Add them as collaborator (run on WSL2 as dare-x)

```bash
gh api repos/dare-x/interview-platform-eng-sandbox/collaborators/<their-username> \
  -X PUT -f permission=read
```

They get email + GitHub notification within ~30 sec.

### 3. Brief them via Teams or email

> Hi [candidate], for our technical round at [time]:
> 1. Check your email for an invite to collaborate on `dare-x/interview-platform-eng-sandbox` → Accept
> 2. Visit https://github.com/dare-x/interview-platform-eng-sandbox
> 3. Click Code → Codespaces → Create codespace on main
> 4. Wait ~3 min for it to build
> 5. When VS Code loads, open `README.md` to begin
>
> You'll share your screen via Teams. Bring Chrome/Edge/Firefox. No prep needed.

## DURING THE INTERVIEW

### 4. Confirm their env is healthy (in their codespace terminal)

```bash
which go kubectl helm aws terraform docker k3d
kubectl get nodes
kubectl -n broken get pods
cd exercises/01-go-mage-mini && go test ./...
```

Expected: 7 tools found, 2 k3d nodes Ready, 3 broken pods (CrashLoopBackOff/ErrImagePull/CreateContainerConfigError), 4 existing Ex 01 tests pass.

### 5. Run the 75-min interview per `.interviewer/INTERVIEWER_GUIDE.md`

| Min | Section |
|---|---|
| 0-5 | Warm-up + open README |
| 5-15 | Verbal probes |
| 15-35 | **Exercise 01 (Go)** — make-or-break |
| 35-55 | Exercise 02 (K8s broken pods) |
| 55-65 | Exercise 03 (AWS IAM) |
| 65-72 | Exercise 04 or 05 (discussion) |
| 72-75 | Their Qs + wrap |

Take real-time notes against the rubric.

## Exercise 01 expected arc (15-20 min)

1. Read EXERCISE.md (~2 min) — should NOT start coding immediately
2. Read spec.go + spec_test.go to learn the pattern (~3 min)
3. Run `go test ./...` baseline (~30 sec)
4. Add Kafka struct + `Kafka *Kafka` field on Spec (~5 min)
5. Re-run tests — existing 4 still pass (~30 sec)
6. Add 2 new tests (Kafka happy + bad partition) (~5 min)
7. Re-run — 6 pass (~30 sec)
8. Update sample-spec.yaml with kafka block (~1 min)
9. `go run . hack/sample-spec.yaml` → "spec valid: ..." (~30 sec)
10. **Bonus**: remove `retention_hours`, re-run, prove defaults work (~1 min)

### Senior vs Mid signals

- **Senior**: reads code before writing; validator tags not `if` blocks; pointer for optional; table tests; error wrapping
- **Mid**: solves it but uses value-type Kafka (not pointer); one happy test only
- **Disqualifier**: rewrites validation in `if` blocks; can't get tests to pass in 30 min

## AFTER THE INTERVIEW

1. **Score within 4 hours** — memory fades.
2. **Remove collaborator**:
   ```bash
   gh api repos/dare-x/interview-platform-eng-sandbox/collaborators/<their-username> -X DELETE
   ```
3. **Ask them to delete their codespace** at https://github.com/codespaces.

## FAQ

**The codespace won't build** — Check `/workspaces/.codespaces/.persistedshare/creation.log` in the codespace terminal for the actual error. If mid-interview blocker, delete + recreate (~3 min lost).

**The candidate can't access the repo** — Most common: didn't accept the invite. Check `https://github.com/<their-username>?tab=repositories` for the pending invitation banner.

**`kubectl get nodes` returns my on-prem cluster** — You're in WSL2, not the codespace. WSL2 has prod kubeconfig active. The candidate's codespace has `k3d-sandbox-*` nodes. **Never run Ex 02's `kubectl apply` on WSL2** — those manifests target k3d, not prod.

**Copilot allowed?** — Your call. Allow as realistic signal, or disable to test pure problem-solving. Tell them upfront.

## Related

- [`PUSH-INSTRUCTIONS.md`](PUSH-INSTRUCTIONS.md) — Push template updates
- [`.interviewer/INTERVIEWER_GUIDE.md`](.interviewer/INTERVIEWER_GUIDE.md) — Model answers + scoring rubric
- [`.interviewer/AWS_INTEGRATION.md`](.interviewer/AWS_INTEGRATION.md) — Optional AWS role for Ex 03
- [`README.md`](README.md) — Candidate-facing intro
