# Exercise 01 — A guard for deploy manifests

**Time:** ~25 minutes · **Language:** Go

## Background (this actually happened)

Our deployment platform creates each application's identity automatically — the app registration, its client ID, its credentials — and delivers those values to the running container. Applications are supposed to consume what the platform gives them.

Browser applications (single page apps) have a `configVars` block in their manifest. Whatever is in it gets written into a ConfigMap and served to the browser as runtime configuration. It is free-form: the platform doesn't inspect it.

Three of our UIs put their **own client ID** in that block, as a literal value, maintained by hand. So the platform generated the correct identity, and the manifest overrode it with whatever a person last typed.

Nobody noticed until an app registration was recreated. The new identity was generated correctly and never reached the browser, so every user got an authentication error. Redeploying didn't help — each deploy faithfully rewrote the same stale value. It took most of a day to find, and two other UIs still carry the same fault today.

**Your job: make the platform refuse a manifest that does this.**

## What's here

```
main.go                        the CLI
internal/spec/spec.go          the manifest model and validation
internal/spec/spec_test.go     tests (4 currently passing)
hack/sample-spec.yaml          a normal API manifest
hack/ui-spec.yaml              a browser app manifest — currently passes, but shouldn't
```

Start by getting your bearings:

```bash
cd exercises/01-go-spec-guard
go test ./...
go run . hack/sample-spec.yaml
go run . hack/ui-spec.yaml
```

That last one exits `0`. By the time you're done it should not.

## The task

**1. Reject hardcoded identity values in `ui.configVars`.**

A value is a problem when it looks like an identity that the platform should have supplied. Exactly where you draw that line is your call — and we'd like to hear the reasoning, because it's a genuine trade-off:

- Too strict and you break teams who have a legitimate reason to pin a value
- Too loose and the bug we just described sails straight through

**2. Make the error message useful.** Whoever hits this is a developer who does not know the backstory, at the moment their deploy fails. They need to know which key is wrong and what to do instead.

**3. Add tests.** At minimum: something that should be rejected, and something that should still pass.

## Constraints

- Keep `Validate` reporting **every** problem, not just the first
- Don't break the four existing tests
- Only dependency available is `gopkg.in/yaml.v3` — the rest is standard library

## If you have time

- `VITE_TASK_API_SCOPES` in the sample is a *different* application's client ID with `/.default` appended. Same class of bug, different shape. Does your rule catch it? Should it?
- One value in that file genuinely is safe to hardcode. Which, and how would you express the exception without hardcoding a list of blessed keys?

## What we're watching for

- Do you read the existing code and follow its conventions, or bolt something on beside it?
- Does the error message tell a developer what to *do*, not just that something is wrong?
- Do you think about false positives before you think about the regex?
- Are your tests table-driven, and do they cover the boundary rather than only the happy path?
- Do you say out loud what you're trading off when you choose how strict to be?

You are not expected to finish every part. Getting the core rule right, well-tested, with a good error message, is a complete answer.
