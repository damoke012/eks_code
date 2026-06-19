# USXpress Platform Engineering — Interview Sandbox

Welcome. This is a live development environment you'll use during the technical interview. It runs entirely in your browser (no VPN, no local setup).

## Confirm the environment is ready

Open a terminal (View → Terminal) and run:

```bash
go version           # expected: go1.24 or later
kubectl get nodes    # expected: 2 nodes Ready (control-plane + agent)
kubectl -n broken get pods   # expected: 3 pods in various broken states
terraform version    # expected: Terraform v1.10.x
aws --version        # expected: aws-cli/2.x
```

If any of those fail, let the interviewer know.

## Format

We'll work through 5 short exercises together (~10-15 min each). I'll watch, ask questions, sometimes nudge. **There's no trick** — I want to see how you think through real problems. You can:

- Google whatever you'd google at work (don't pretend you've memorized every flag)
- Ask clarifying questions before you dive in
- Say "I don't know, but here's what I'd try" — that's a strong answer
- Stop and explain your reasoning at any point

## The exercises

| # | Topic | Time | What you'll do |
|---|---|---|---|
| 1 | [Go — extend a deploy CLI](exercises/01-go-mage-mini/EXERCISE.md) | 20 min | Add a feature to a small Go CLI similar to what we use in production |
| 2 | [Kubernetes — triage broken pods](exercises/02-k8s-broken-pods/EXERCISE.md) | 20 min | Diagnose 3 broken pods in different ways; fix at least 2 |
| 3 | [AWS — fix cross-account IAM](exercises/03-aws-cross-account/EXERCISE.md) | 10 min | A Terraform file has an incorrect trust policy; fix it |
| 4 | [Terraform — state split design](exercises/04-tf-state-split/EXERCISE.md) | 10 min | Sketch a refactor of a monolithic Terraform module |
| 5 | [Observability — SLO design](exercises/05-slo-design/EXERCISE.md) | 10 min | Design SLIs and SLOs for a fictional API |

You don't need to finish them all. Pace yourself with the interviewer.

## How this codespace works

- This is a [GitHub Codespace](https://github.com/features/codespaces) — a temporary cloud dev environment
- It has its own Kubernetes cluster (`k3d`) inside — feel free to break it, you can't break anything that matters
- Terraform runs in `plan`-only / `validate`-only mode (no real AWS resources are created during the interview)
- The session auto-pauses after 30 min of inactivity and is deleted after the interview

Good luck — and we mean it when we say "show your thinking out loud."
