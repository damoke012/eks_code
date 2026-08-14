# Exercise 02 — An API is returning 401 to everything

**Time:** ~20 minutes · **No code required**

This is a real production incident, anonymised. The evidence in `evidence/` is what we actually had, in roughly the order we got it. Nothing has been added to make it solvable and nothing has been removed to make it harder.

Work it however you'd work it on a Tuesday. Talk as you go.

## Start here

```bash
cd exercises/02-auth-outage/evidence
cat 01-report.md
ls -1
```

Read the files in whatever order you want. You can `grep`, `sort`, `diff`, `jq` — whatever helps.

## What we'd like from you

**1. What is your first hypothesis, and what would falsify it?**
State it before you go looking. We're interested in whether you set up a test you could fail.

**2. What actually happened?**
Say what the evidence supports, and be explicit about where you're inferring rather than reading.

**3. How would you fix it — today, in production?**
There is more than one defensible answer. We care about the trade-offs you name, especially blast radius and ordering.

**4. What would stop it recurring?**
The team had already redeployed the failing service twice before calling us. If a fix requires people to remember something under pressure at 2am, it isn't a fix.

## Things worth being careful about

The application team's first instinct was "redeploy orders-api". They did it twice. It didn't help, and there's a reason it couldn't have — see if you can work out why from the evidence.

One line of the access log is not like the others. If you spot it, say what it changes about the scope of the problem.

## What we're watching for

- You read the evidence before theorising, and you say what you're looking for
- You notice that two files, compared, answer the question outright
- You distinguish "the API is broken" from "the callers are stale" — they need opposite fixes
- You think about **ordering**: if fixing service A breaks service B, which goes first?
- You're willing to say "this evidence doesn't tell me that" instead of filling the gap with a guess
- You ask what a redeploy actually *does* in our platform rather than assuming

## If you finish early

The same platform recreates an application's identity under certain conditions. What would you put in place so that the *next* time it happens, somebody knows within minutes rather than after a customer reports it? Be specific about what you'd measure — "add monitoring" isn't an answer.
