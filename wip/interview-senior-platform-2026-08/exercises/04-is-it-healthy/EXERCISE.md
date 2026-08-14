# Exercise 04 — Is this service healthy?

**Time:** ~15 minutes · **No code required**

## The situation

It's 23:10. A director is on the call and asks a fair question:

> Are we still seeing errors in production, yes or no?

You have four sources of evidence in `evidence/`. Read them and answer.

```bash
cd exercises/04-is-it-healthy/evidence
cat 01-question.md
ls -1
```

## What we'd like from you

**1. Answer the question.** Out loud, the way you'd say it on the call. A director needs a decision, not a lecture — but they also need to know what you're unsure of.

**2. Reconcile the sources.** Two of them say everything is fine. Explain precisely *why* they say that, rather than just picking the one you trust.

**3. What would you have needed** to answer this in thirty seconds instead of fifteen minutes?

## What we're watching for

- You notice the thing that makes the healthy-looking evidence misleading, and can articulate the mechanism
- You don't dismiss the metrics as "wrong" — they're accurate, they're just answering a different question
- You treat the operations analyst's message as evidence, not as anecdote
- You're precise about the difference between *"we have no errors"* and *"we cannot see errors"*
- You resist giving a confident yes or no where the honest answer is "yes, and here's what I can't tell you"

## The harder question, if you get there

The pattern here — a failure that never surfaces as an HTTP error — is not rare, and it defeats most monitoring people put in place by default.

If you owned this platform, what would you *actually build* so this class of failure is caught? "Better alerting" is not an answer. We want to know what signal you'd emit, who owns emitting it, and how you'd stop it rotting six months from now when nobody remembers why it exists.

There's a trade-off underneath that we'd like you to name: platform teams can enforce very little inside application code, and the useful signal usually lives there. How do you get it without becoming the team that nags?
