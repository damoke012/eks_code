# SOP — MongoDB "connection pool is in paused state"

**Audience:** Application teams · **Owner:** Cloud/Platform · **Version:** 1.0 (2026-08-11)

---

## Symptom

```
MongoDB.Driver: The connection pool is in paused state for server
pl-0-us-east-2.<id>.mongodb.net:1025
```

Repeats continuously. The service cannot reach MongoDB. Pods are Running and Ready.

Seen on `orders/order-api` on 2026-07-30 and again on 2026-08-10.

---

## ⚠️ This is NOT a network or Atlas outage

Verified on 2026-07-30 across DNS, VPC endpoint, security groups and routing — **all healthy**.
MongoDB Support confirmed independently that Atlas never rejected or closed the connections.

**"Pool paused" is state inside the .NET MongoDB driver.** After a single failure the driver marks
the server Unknown and stops the pool. **It does not recover on its own.** The application cannot
reach MongoDB even though nothing is wrong with the network.

That is why it looks like a total outage from inside the app and like perfect health from
everywhere else.

---

## ✅ The fix

**Restart the pods.** A new process gets a new connection pool and clean driver state.

Choose whichever you have access to — both do the same thing:

| Method | How |
|---|---|
| **Octopus (preferred)** | Deploy the **same version again** — a normal release |
| **kubectl** | `kubectl -n <namespace> rollout restart deploy/<app>` |

`rollout restart` is a **rolling** restart: new pods start and become Ready *before* old ones stop.
**No downtime.** It does **not** scale to zero.

Confirm recovery:

```bash
kubectl -n <namespace> get pods
kubectl -n <namespace> logs deploy/<app> --since=5m | grep -i "paused state"
```

Pods Running with no new restarts, and no "paused state" lines in the last five minutes.

---

## ❌ Do NOT use a Clean release

**A clean release will fix the symptom and cause a much larger outage.**

A clean release tears down and rebuilds all of the app's resources. Two of those are shared:

1. **The Azure AD app registration** is destroyed and recreated with a **brand-new client ID**.
   Every other service that calls this one cached the old ID at *its* deploy time and cannot
   refresh it. They all fail authentication with `AADSTS500011`, at token acquisition, before any
   request is sent. Recovery requires a **full release of every consumer**.

2. **The DNS record** is deleted and recreated. Resolvers cache the negative answer, so the API is
   unreachable for **5–10 minutes** after the record is already back.

On 2026-08-10 three clean releases of `orders-api` produced four client IDs and left **15 services
unable to authenticate for over 16 hours**.

**A clean release does nothing for a paused pool that a normal restart doesn't do.** The only part
that helps is restarting the process.

---

## Escalation — capture this before or while restarting

The restart clears the symptom and destroys the evidence. **Before restarting**, capture the
**original exception**, which appears *before* the repeating "paused state" lines:

```bash
kubectl -n <namespace> logs deploy/<app> --since=2h | grep -B40 -m1 "paused state" > /tmp/pool-pause.log
```

Attach that to the ticket. It names the real cause — authentication failure on connection
creation, TLS handshake failure, an unhealthy replica-set member, or pool saturation.

**This has never been captured**, which is why the problem recurred after 30 July. Getting it once
is what lets us stop it happening again rather than clearing it each time.

---

## Quick reference

| | |
|---|---|
| **Do** | Normal Octopus release, or `kubectl rollout restart` |
| **Don't** | Clean release. Rollback (the pool state isn't in the image). |
| **Capture first** | The exception *before* the "paused state" lines |
| **Escalate to** | Cloud/Platform, with that log attached |

---

## Related

- Incident 2026-07-30 — `wip/incidents/2026-07-30-atlas-privatelink-prod.md`
- Incident 2026-08-10 — orders-api auth outage; see `/prod-auth-triage`
- Delivery model — `docs/architecture/dx_app_delivery_workflow.md`
