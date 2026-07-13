# Entra app-reg secret rotation — RUNBOOK (DRAFT, unvalidated)

> Status: DRAFT. Steps below are the agreed plan (call 2026-07-10) but NOT yet tested.
> Validate in DPL → dev first, capture gotchas, then promote to a signed-off playbook.
> Once validated, this is a candidate to become a `/rotate-secret` skill (like pr-review-rw).

## Preconditions
- Azure access for the operator (Parul) — granted by Steve/Marvel.
- Confirm the app is still in use (namespace/deployment exists; Entra sign-in logs). If stale → retire the registration instead of rotating (confirm with owner, cc Steve, keep the record).

## Rotation steps
1. **Azure AD:** create a NEW client secret on the app registration. Note new value + new expiry. Do NOT delete the old secret yet.
2. **AWS Secrets Manager:** update the secret value (SM is source of truth).
3. **Terraform state:** update the state file(s) so they reference the new secret — otherwise the next TF run reconciles back to the old secret. (Primary gotcha.)
4. **Determine consumption point:** is the secret an env var (pipeline injects from SM) or a mounted/uploaded secret the app reads directly? Handle accordingly.
5. **Cluster:** delete the expiring Kubernetes secret → rerun the deploy pipeline → it pulls the new value from SM into the pod.
6. **Verify:** app authenticates successfully (check pod logs / an auth healthcheck). Confirm no other consumers still reference the old secret.
7. **Cleanup:** once verified healthy, remove the old Azure secret.

## Test protocol
- DPL first (lowest), then one dev app end-to-end, then higher envs.
- Prod rotations: do them together on a call so the whole team is present if something breaks.

## Rollback / what-could-go-wrong
- Worst case = rebuild the app from scratch (recreates auth). Avoid in prod.
- If TF state not updated → old secret resurrected on next apply.
- If secret is consumed in a place besides SM/env (uploaded cert/secret) → app still fails after pipeline rerun.

## Log (fill in during testing)
- [ ] DPL test — date, app, result, gotchas
- [ ] Dev test — date, app, result, gotchas
- [ ] Prod xpm-classic (7/17) or first prod app — date, result
