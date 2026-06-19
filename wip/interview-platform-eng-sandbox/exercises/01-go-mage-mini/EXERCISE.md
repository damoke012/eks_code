# Exercise 01 — Extend a deploy-spec CLI in Go

**Time:** ~20 minutes
**Repo layout:** `exercises/01-go-mage-mini/`

## What's here

A small Go CLI named `mage-mini` that reads a YAML deployment spec and validates it. It's a simplified version of the tool we maintain in production (the real one is ~3,000 lines and orchestrates Octopus + Terraform + Kubernetes).

```
01-go-mage-mini/
├── main.go                       # CLI entry point — parses spec from a file path
├── internal/spec/
│   ├── spec.go                   # Spec struct + Parse + Validate
│   └── spec_test.go              # Existing tests for the current spec
├── hack/sample-spec.yaml         # A valid input you can use to test
└── go.mod
```

Read the existing code briefly. The current `Spec` supports `name`, `octopus`, and `infrastructure.buckets`.

## What you're going to add

Real app teams have asked us to support a new `kafka:` block in their specs. Add it.

### Requirements

1. Add a `kafka:` block to `Spec` with these fields:
   - `topic_name` (string, required, non-empty)
   - `partition_count` (int, required, **must be >= 1**)
   - `replication_factor` (int, required, **must be between 1 and 5**)
   - `retention_hours` (int, optional, default 24, must be >= 1 if specified)

2. Use the validator pattern that's already in `spec.go` (`go-playground/validator/v10`).

3. Make sure the existing tests still pass: `go test ./...`

4. Add at least 2 new test cases:
   - One that successfully parses + validates a kafka block
   - One that fails validation (e.g. partition_count = 0) with a clear error

5. Update `hack/sample-spec.yaml` to include a valid `kafka:` block so `go run . hack/sample-spec.yaml` exits 0.

## Run it

```bash
cd exercises/01-go-mage-mini
go test ./...                        # should pass before AND after your changes
go run . hack/sample-spec.yaml       # should print "spec valid" with your kafka block added
```

## What we're looking for

- You read existing code before writing new code
- You follow the existing pattern (don't reinvent validation in `if` blocks)
- Idiomatic Go: error wrapping, table tests, proper struct tags
- You ask clarifying questions if a requirement is ambiguous

## Hints (use freely)

- `goccy/go-yaml` is already imported — that's what parses the YAML
- `github.com/go-playground/validator/v10` has tags like `validate:"required,min=1,max=5"` — use them
- Optional fields with defaults: use `defaults.Set` from `creasty/defaults` (already imported) with the `default:"24"` struct tag
- Look at how `Infrastructure.Buckets` is handled — kafka should follow the same shape

## Code snippets

[`SNIPPETS.md`](SNIPPETS.md) contains the actual code blocks you'll need — Kafka struct, the field on `Spec`, the two new tests, and the YAML to add. You can paste them verbatim. **You still need to figure out which file each goes in, where in the file, and what commands to run to verify.** That's the part we're scoring.
