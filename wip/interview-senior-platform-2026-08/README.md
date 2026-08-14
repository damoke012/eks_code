# Senior Platform Engineer — Technical Interview

Welcome. This is a live environment for the technical round. It runs entirely in your browser — no VPN, no local setup, nothing to install.

## Confirm the environment is ready

Open a terminal (**View → Terminal**) and run:

```bash
go version                    # go1.24 or later
kubectl get nodes             # 2 nodes Ready
kubectl -n missions get pods  # 2 pods, one of them unhappy
terraform version             # v1.10.x
jq --version                  # jq-1.7 or later
```

If any of those fail, tell the interviewer — don't spend time debugging it yourself.

## What this is

Every exercise here is a **real problem this team hit in production**, with the specifics anonymised. None of them are puzzles, and none have a single hidden "correct" answer we're waiting for you to guess.

We are much more interested in *how you get to an answer* than whether you land on ours. Specifically:

- Do you look at evidence before forming a theory?
- Do you notice when your measurement is lying to you?
- Do you say "I don't know, here's what I'd check" instead of guessing confidently?
- Do you distinguish a symptom from a cause?

You can google anything you'd google at work. Nobody memorises flags. Ask clarifying questions before you start — that's a positive signal, not a stall.

## The exercises

| # | Topic | Time | What you'll do |
|---|---|---|---|
| 1 | [Go — a guard for deploy manifests](exercises/01-go-spec-guard/EXERCISE.md) | 25 min | Extend a small Go CLI so it catches a class of config bug |
| 2 | [Incident — an API returns 401 to everything](exercises/02-auth-outage/EXERCISE.md) | 20 min | Work a real outage from the evidence we had at the time |
| 3 | [Kubernetes — a deploy that can't finish](exercises/03-k8s-envfrom-deadlock/EXERCISE.md) | 20 min | Diagnose and recover a stuck rollout |
| 4 | [Observability — is this service healthy?](exercises/04-is-it-healthy/EXERCISE.md) | 15 min | Four sources disagree. Decide what you believe |
| 5 | [Design — identity that doesn't go stale](exercises/05-identity-design/EXERCISE.md) | 15 min | Whiteboard-style discussion, no code |

**You will not finish all five.** That's expected and it's fine — we'd rather see two done thoughtfully than five rushed. Pace with the interviewer.

## How this environment works

- A [GitHub Codespace](https://github.com/features/codespaces) — a temporary cloud dev environment on your own account
- It contains its own Kubernetes cluster (`k3d`). Break it freely; nothing real is attached
- Terraform is `validate`/`plan` only — no cloud credentials, no resources created
- All names, IDs, hostnames and account numbers are **synthetic**. Nothing here is a real credential
- The session pauses after 30 minutes idle; delete it after the interview

## One request

Think out loud. Silence is the hardest thing to assess — if you're reading, say what you're looking for. If you're stuck, say what you've ruled out. We've all been stuck; we can't score what we can't hear.

Good luck.
