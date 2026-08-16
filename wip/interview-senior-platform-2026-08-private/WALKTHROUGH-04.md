# Exercise 04 — interviewer walkthrough

Fifteen minutes, no code, no cluster. The sharpest of the five: the healthy-looking evidence is
**accurate**, and that is the whole point.

---

## Setting it up

> *"It's 23:10. A director is on the call and asks: 'Are we still seeing errors in production, yes
> or no?' You've got four sources. Read them and answer — the way you'd say it on the call."*

```bash
cd /workspaces/interview-senior-platform/exercises/04-is-it-healthy/evidence
cat 01-question.md
ls -1
```

Then let them read in whatever order they choose. The order they pick is itself a signal — someone
who opens the metrics first and stops there has answered the wrong question.

```bash
cat 02-prometheus.txt        # mesh response codes: 5xx = 0, over 15m and 24h
cat 03-pod-status.txt        # 3/3 pods Running, 2/2 containers, 0 restarts, normal CPU/memory
cat 04-app-log-sample.txt    # the answer is in here
cat 05-business-check.md     # the operations analyst
```

The line that resolves it:

```bash
grep -nE 'ERR|Request finished' 04-app-log-sample.txt
```

An `ERR` with a `NullReferenceException`, and eleven lines later:

```
[23:04:18 INF] Request finished POST /v1/sbx-missions/patch - 200 - 41.8ms
```

---

## Ground truth

The application caught its own exception, logged it, and returned **HTTP 200**. The request
succeeded; the work didn't. Legs are silently not being created.

## Reconciling all four — this is question 2, and the real test

- **Metrics show 100% 200s because the service really did return 200.** The metric is accurate. It
  is answering *"did the request complete"*, not *"did the work happen"*.
- **Pods are healthy because nothing crashed.** Liveness and readiness measure the process, not the
  outcome. Zero restarts is exactly what you'd expect from a caught exception.
- **The application log is the only place the failure appears** — and only if you go looking for
  `ERR` in a stream that is otherwise 200s.
- **The operations analyst is ground truth.** A test order at 22:52, no leg. Checked again at 23:06,
  still nothing. Twice. That is a controlled experiment, not an anecdote.

Note the analyst's own last line — *"I'm not seeing any errors though"* — is the same trap the
monitoring fell into, from the other end.

## The answer we want on the call

> *"Yes, it's still failing. The service is returning 200 while swallowing the error, so nothing in
> our monitoring will show it. The only reliable signal right now is checking whether the work
> actually happened — and the last two checks say it didn't."*

Confident about what's known, explicit about what isn't. A director can act on that.

## Question 3 — what would have made this thirty seconds

Anything that measures the outcome rather than the transport: a legs-created-per-minute counter
with an alert on absence, an unhandled-exception count surfaced regardless of HTTP status, or a
synthetic transaction doing what the analyst did by hand.

---

## Signals

**Strong**

- Reads the app log before forming a verdict, and greps for `ERR` rather than skimming
- Says the metrics are *accurate but answering a different question* — in those terms or their own
- Treats the analyst's test as the most reliable evidence in the folder, because it measures outcome
- Distinguishes *"we have no errors"* from *"we cannot see errors"*
- Notices the exception is caught, and that this is a deliberate code path rather than a crash

**Weak**

- *"Metrics look clean so we're fine"* — didn't read the log
- *"The metrics are wrong"* — they aren't, and this matters: a candidate who dismisses accurate
  instrumentation will dismiss it next time too
- Treating the analyst as anecdotal because it isn't a dashboard
- A confident yes/no with no statement of what they can't see

## The harder question

> *"What would you actually build so this class of failure is caught? 'Better alerting' is not an
> answer. What signal, who owns emitting it, and how does it not rot in six months?"*

Good directions: a business-outcome metric owned by the application (legs created per minute) with
an alert on absence; the platform's log pipeline surfacing unhandled-exception counts regardless of
HTTP status; a synthetic transaction. What we want is specificity plus an answer to *how does this
not rot* — usually ownership, or making the signal something the team already looks at daily.

The trade-off to draw out: platform teams can enforce very little inside application code, and the
useful signal usually lives there. How do you get it without becoming the team that nags? There is
no model answer — listen for whether they've thought about influence versus enforcement.
