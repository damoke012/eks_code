# Exercise 02 — Triage 3 broken pods in Kubernetes

**Time:** ~20 minutes
**Cluster:** local k3d, namespace `broken`

## What's here

Three pods have been deployed in the `broken` namespace, each in a different broken state. Your job:

1. Identify what's wrong with each, **showing your diagnostic path** (commands you ran, signals you read)
2. Propose a fix for each
3. Apply the fix for at least 2 of them

We care more about **the way you diagnose** than the speed of the fix.

## Start here

```bash
kubectl -n broken get pods
```

You should see 3 pods, all in some failing state. Walk us through how you'd approach each.

## Hints (use when you need them)

- `kubectl describe pod <name> -n broken` — events tell you a lot
- `kubectl logs <name> -n broken --previous` — for crashed containers
- `kubectl get events -n broken --sort-by='.lastTimestamp'` — chronological
- `kubectl exec -it <name> -n broken -- /bin/sh` — for containers that are *currently* running but misbehaving
- `kubectl top pods -n broken` — needs metrics-server (it's installed)

## Manifests

The pod manifests live in `manifests/`. **Don't open them yet** — diagnose first from the cluster, then look at the YAML to confirm.

## What we're looking for

- You don't jump straight to a fix — you diagnose first
- You distinguish symptoms from causes
- You explain your reasoning out loud
- For OOM specifically: you don't just bump the memory limit
- For ImagePull failures: you distinguish "no such image" from "no permission to pull"
- For CrashLoop: you read app-level logs, not just pod events

## When you're done

Talk through what you'd add to monitoring/alerting so you'd see these classes of failure proactively — not just when a user reports it.
