---
name: explain-plainly
description: Write so the reader can act — any answer to Doke, any message he forwards, any document another team reads (a status, a finding, a design, a review, a diagram caption, a Confluence page). Use when the material is technical and the reader is not deep in it, or when asked to "keep it simple", "make it easy to understand", or "explain it plainly".
---

# Explain plainly

Doke assigns work and briefs people. Idris, the app teams and the network team read what he
forwards. **A sentence they cannot act on costs a meeting.**

Plain is not simplified. Every identifier someone needs in order to act stays exactly as it
is — `sg-0c8f8db29b16a1477`, ports 1024-1026, `10.10.82.0/24`. What changes is the order, and
what gets said first.

## Lead with the thing, name the mechanism once

The mechanism's name is the last thing the reader needs and the first thing we reach for.

| Instead of | Write |
|---|---|
| "The Atlas cluster is behind an AWS PrivateLink interface endpoint, so on-prem has no route" | "The database only accepts connections from one specific AWS network, and on-prem is not in it" |
| "ESO writes a partial secret on `SecretSyncedError`" | "If a key is missing, the sync still reports success and the pod dies at startup" |

Then name it once — *PrivateLink*, *External Secrets* — so the reader can search for it and
talk to the team that owns it. Naming it never comes first.

## Two sentences before any detail

**The issue** in one sentence. **The fix** in one sentence. Everything else is support.

If the two sentences cannot be written, the work is not finished — a thing that takes three
sentences to state is usually two things.

## Say what it is not

The reader's wrong guess is the expensive part. *"The database is unreachable"* is heard as a
redesign, a delay, a new network. One short list closes all of them:

> Not a redesign. Not a new network. Not a credential problem. Not a reason to pause.

## Put the number beside what it means

A measurement alone invites the opposite reading. **405 was a pass**, and a reader who does
not know that reports a failure. **12 credentials, not 3** only lands with "the other 9 come
from a system the app team cannot see."

## Concede the real cost

A change with no downside reads as a sales pitch and gets trusted less, not more. One honest
line buys the rest: *"A setting that is a web form today becomes a pull request. That is the
point, and it is slower."*

## End on the owner and the next action

Who does the next thing, and what exactly it is. A document that ends on analysis leaves the
reader to invent the task, and they will invent a different one.

## Drafting something Doke sends

Write it the way **he** writes: short plain lines, no headings, no bold, no tables, no
preamble ([[dokes-own-voice-is-plain]]). Keep every identifier. The structure that helps a
document get read gets in the way of a message getting sent.

⚠️ **A finding goes in prose, never in a ```bash fence.** A quoted measurement in a fence is
pasted into a terminal and runs — measured twice. Fences hold runnable lines only
([[handing-over-commands]] mode 5).

## The check

> Could someone who joined this week read this and do the next thing?

If they would have to ask what a word means before acting, replace the word. If they would
have to assemble the point from three paragraphs, say it at the top.

## Why this exists

On 2026-10-20 a database connectivity finding could have been delivered as *"the Atlas
PrivateLink endpoint's security group does not admit the on-prem CIDR."* True, complete, and
it would have produced a meeting. What shipped instead:

> The database only accepts connections from inside one AWS network, and on-prem is not
> inside it. The road between the datacenter and AWS already exists — only the gate is shut.

Same facts. One of them can be forwarded.
