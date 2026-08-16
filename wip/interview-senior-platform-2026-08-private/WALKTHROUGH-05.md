# Exercise 05 — interviewer walkthrough

Fifteen minutes, discussion only, no tooling. **There is no right answer** — this is the exercise
where you find out whether they can hold an opinion without absolutes.

Use it as the reserve: if they're strong and fast, or if the environment breaks and you need
something that needs nothing but a conversation.

---

## Setting it up

> *"Last one is a design conversation — no code. Our platform owns application identity: every
> deploy it creates or updates a registration and produces a client ID, a secret and scopes.
>
> Server-side services get those through the secret store into a Kubernetes Secret and read them as
> environment variables. They never state their own identity, so when a registration is recreated
> they heal on the next deploy.
>
> Browser apps can't hold a secret, so their identity arrives as plain configuration served to the
> page — today from a free-form block in the manifest that teams maintain by hand. So when a
> registration is recreated, services heal and browser apps break permanently.
>
> Three teams have this. Two of them have never been bitten, so they don't know."*

Then give them `EXERCISE.md` and let them read the four questions.

---

## The observation that separates candidates

**A browser cannot hold a *secret*. A client ID is not a secret.**

It's public by design — it ships in the page, it's visible in every auth redirect. The reason it's
hand-maintained isn't a security constraint at all; it's that nobody built a delivery route for the
non-secret half of the identity.

A candidate who notices this reframes the whole problem: it isn't "how do we secure this", it's
"why is there no supply route". They usually get to the fix in a sentence — have the platform render
the value into the served configuration, the same way it renders the ConfigMap for a service.

Candidates who miss it tend to design elaborate secret-distribution machinery for a value that's
printed in the browser's address bar. Ask directly if it doesn't come up in ten minutes: *"is a
client ID a secret?"*

## Q1 — the design

Reasonable shapes, roughly in ascending order of quality:

- Platform renders identity into the served config; the manifest block stops carrying it
- Platform-supplied values **win** over manifest values on collision, and the deploy says so out loud
- The manifest declares *intent* (`auth: platform`) rather than values, so there's nothing to typo
- Best: consumers reference a **stable identifier** that survives recreation — the registration's
  identity changes, the reference doesn't. This kills the whole class rather than this instance

## Q2 — migration

The interesting half is the two teams not in pain. Listen for:

- Fix the bitten team first — they have motive and will test it for you
- The unbitten two need the change to cost them nothing, or they will not prioritise it
- Detection before enforcement: find every manifest carrying a pinned identity, tell the owners what
  it means, *then* start refusing new ones
- Ship it as a warning first and a failure later, with a date

A candidate who says "make them all refactor" hasn't worked with teams who have roadmaps.

## Q3 — where enforcement lives

Each option has a different failure mode, and naming the failure mode matters more than the choice:

| Where | Fails how |
|---|---|
| Pipeline validator | bypassed by anything not going through the pipeline; easy to disable under deadline |
| Platform-side override | value is right but the manifest still lies; the next reader is misled |
| Admission controller | catches everything, including the emergency you needed at 2am |
| Review convention | works until the reviewer is busy |

Strong answers combine: **platform supplies the truth, validator makes the mistake visible early,
admission is the backstop for what matters most.** Also listen for whether the exception path is
designed in from the start rather than bolted on after the first escalation.

## Q4 — blast radius

Their fix ships too. Worst case: the platform now supplies identity to every browser app at once,
and a bug means *everyone* gets the wrong value rather than one team.

Good answers: roll it out per-application; keep the old path working during transition; compare
generated-versus-served for one app before touching the rest; a signal that tells you within minutes
whether logins are succeeding rather than waiting for a report.

## The pushback question — ask this every time

> *"You build this, and a team says 'we need to pin our client ID, we have a reason.' Do you let
> them?"*

There is no correct answer. What you're listening for:

- Do they ask **what the reason is** before deciding? Sometimes it's legitimate — a shared
  registration, a third party that can't rotate
- Do they distinguish *make it impossible* from *make it obvious*?
- Is the exception **visible, owned and dated** — an explicit opt-out field with a name attached, not
  a quiet special case
- Do they see that one silent exception becomes the pattern in a year?

Absolutes in either direction are the weak answer. *"Never allow it"* means they'll be routed around.
*"Sure, it's their call"* means the platform guarantees nothing.

---

## Signals

**Strong**

- Notices a client ID isn't a secret, and says so early
- Separates make-it-impossible from make-it-obvious, and knows when each fits
- Has a defensible position on enforcing versus enabling, without absolutes
- Thinks about the two teams not yet in pain
- Ships something incremental; treats a rewrite as the last resort
- Designs the exception path deliberately

**Concerning**

- Designs secret-distribution machinery for a public value
- "Just add a policy that blocks it" with no exception path and no migration
- Cannot say what happens when their own fix is wrong
- Treats the unbitten teams as a communication problem rather than a sequencing one
