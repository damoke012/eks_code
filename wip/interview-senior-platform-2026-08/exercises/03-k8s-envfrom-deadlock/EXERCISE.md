# Exercise 03 — A production deploy that cannot finish

**Time:** ~20 minutes · **Cluster:** local k3d, namespace `missions`

## The situation

It's 22:15. An application team needs a fix in production tonight. Their deployment has failed twice already and they've asked you for help.

The deployment tool runs Terraform to create the app's supporting resources, then a Helm release that waits for the rollout to become healthy before reporting success. Right now it is sitting there, not finishing.

```bash
kubectl -n missions get pods
```

## What we'd like from you

**1. Diagnose it.** What is wrong, and how do you know? Show your path — the commands, and what each one told you.

**2. Answer this before you change anything:** is the service currently up or down? Say how confident you are and why. It matters for what you're allowed to do next.

**3. Recover it.** Get the rollout to complete. There is a right answer and several wrong ones that appear to work.

**4. Then tell us what you'd change** so this can't happen again — in the platform, not in a runbook.

## What's available to you

```
manifests/     what the platform applied (reference — diagnose from the cluster first)
state/         the platform's Terraform state for this application
```

The state file is real in shape: it's what our deployment tool actually keeps in S3, one key per module. Whether you need it is up to you to work out.

## Rules of engagement — treat this as production

- Nothing here is disposable. Assume every object is load-bearing until you've shown otherwise
- `kubectl delete deployment` is not an answer
- If you'd normally check something before a destructive action, check it here too — we're watching for that specifically
- You may create, patch and delete objects. Say what you expect to happen *before* you press enter

## What we're watching for

- You diagnose before you act, and you distinguish the stuck thing from the working thing
- You realise the running pods and the failing pod are in different states for a reason
- You spot the risk that the currently-healthy pods are one eviction away from being unrecoverable — and you say so
- You recover the missing object with its *correct* content rather than inventing something plausible
- You think about whether your fix leaves the platform's own record consistent
- You don't reach for the destructive option because it's faster

## If you finish early

The team's instinct in the real version of this was to run a "clean" redeploy — tear everything down and rebuild it. That would have worked, and it would also have caused a much larger outage.

Given what you now know about how this platform assembles an application, what would that have destroyed, and who would have found out first?
