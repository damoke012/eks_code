# Exercise 05 — Identity that doesn't go stale

**Time:** ~15 minutes · **Discussion, no code**

This is a design conversation. Sketch on paper, in a scratch file, or just talk. There is no right answer and we are not scoring you against one.

## The system, as it stands

Our deployment platform owns application identity. On every deploy, for each application, it creates or updates an identity provider registration and produces a client ID, a secret and a set of scopes.

Those values reach a running application by two different routes:

**Server-side services** — the platform writes the values to a cloud secret store; a controller syncs them into a Kubernetes Secret; the pod reads them as environment variables. The application never states its own identity. If a registration is recreated, the next deploy delivers the new values automatically.

**Browser applications** — a browser cannot hold a secret, so the identity has to arrive as plain configuration served to the page. Today that comes from a free-form `configVars` block in the application's manifest, which teams maintain by hand. The platform generates the correct value and never gets asked for it.

The consequence: when a registration is recreated, server-side services heal themselves and browser applications break permanently. No redeploy fixes them, because each deploy rewrites the same hand-typed value.

Three teams have this today. Two of them have never been bitten, so they don't know they have it.

## What we'd like from you

**1. How would you fix it?** Not the workaround — the design. Where should the value come from, how should it get to the browser, and what should happen if a team tries to override it?

**2. Migration.** Three applications are on the broken pattern in production, owned by three different teams with their own roadmaps. You cannot make them all stop and refactor. What's your sequencing, and what do you do about the two teams who currently have no reason to care?

**3. Where does enforcement live?** A validator in the pipeline, a platform-side override, a policy admission controller, a code review convention — each has a different failure mode. Pick one and defend it. What happens when someone needs a legitimate exception?

**4. Blast radius.** Your fix will itself be deployed. What's the worst thing that happens if it's wrong, and how would you know quickly?

## What we're watching for

- You ask what the constraint actually is before designing — a browser can't hold a secret, but a *client ID* isn't a secret. Do you notice that?
- You separate "make it impossible" from "make it obvious", and know when each is appropriate
- You have an opinion about platform teams enforcing things versus enabling them, and can defend it without absolutes
- You think about the teams who aren't in pain yet, because they're the ones who'll be surprised
- You'd ship something incremental rather than a rewrite

## A question we'll probably ask

Suppose you build this and a team pushes back: *"we need to pin our client ID, we have a reason."*

Do you let them? What do you need to know first, and what would you put in place so their exception doesn't quietly become everyone's pattern in a year?
