# Exercise 01 — Extend the spec parser (INTERVIEWER SOLVE NOTES)

**For interviewer eyes only. Never share with candidates. Never push to a public/candidate-facing repo.**

## What the exercise tests

This is **not** a Go-syntax test. SNIPPETS.md gives the candidate every line of code they need (since the post-`cefacc7` tightening). What we're testing:

1. **Codebase navigation** — can they find the right file (`internal/spec/spec.go`, `internal/spec/spec_test.go`, `hack/sample-spec.yaml`) without being told?
2. **Pattern recognition** — can they see where in `spec.go` the struct belongs, where in `Spec` the new field goes, where existing tests live?
3. **Verification discipline** — do they run `go test ./internal/spec/...` after each step, or wait until the end?
4. **Understanding of validator tags** — can they explain `required`, `min`, `max`, `omitempty`, `dive`?
5. **Understanding of pointer vs value** — can they explain why `*Kafka` not `Kafka`?
6. **Understanding of defaults** — can they explain `creasty/defaults` + the `default:"24"` tag?
7. **End-to-end demonstration** — can they show sample YAML parses, validates, defaults fire?

A candidate who pastes correctly but can't explain WHY is mid. A candidate who reads existing code first, navigates without being told, and explains the design decisions is strong.

## SNIPPETS.md context (post-`cefacc7` tightening)

The candidate-facing `SNIPPETS.md` was tightened on 2026-06-09:

- **No more "F/G/H whole-file paste"** shortcuts — they can't just nuke the existing file and paste a finished version
- **No more descriptive labels** like "The new Kafka struct" or "YAML addition" — snippets are numbered 1-5 with NO indication of what each is or where it goes
- They still get the actual code verbatim

This means the EXERCISE is now genuinely about **finding the right file + right placement** rather than typing speed. A candidate who paged through SNIPPETS.md before the tightening could have finished in 2 minutes. Now they have to read existing code.

## Exercise structure (the files they need to find)

```
exercises/01-go-mage-mini/
├── EXERCISE.md          # task description
├── SNIPPETS.md          # 5 numbered code blocks (no telegraphing)
├── hack/
│   └── sample-spec.yaml  # ← Snippet 5 goes here
├── internal/
│   └── spec/
│       ├── spec.go       # ← Snippets 1, 2 go here
│       └── spec_test.go  # ← Snippets 3, 4 go here
├── go.mod
├── go.sum
└── main.go               # tiny entry point that calls ParseFile + Validate
```

Total ~5 files to navigate. Senior reads `EXERCISE.md` first, then opens `spec.go` to see the existing pattern, THEN looks at SNIPPETS.md.

## The five snippets — deep walkthrough

### Snippet 1 — the `Kafka` struct definition

```go
type Kafka struct {
    TopicName         string `yaml:"topic_name" validate:"required,min=1"`
    PartitionCount    int    `yaml:"partition_count" validate:"required,min=1"`
    ReplicationFactor int    `yaml:"replication_factor" validate:"required,min=1,max=5"`
    RetentionHours    int    `yaml:"retention_hours,omitempty" validate:"omitempty,min=1" default:"24"`
}
```

#### Layer 1 — what the candidate sees

A struct type with 4 fields, each tagged with `yaml:`, `validate:`, and one with `default:`.

#### Layer 2 — plain English

A new top-level deployment-spec block describing a Kafka topic. Same conventions as the existing `Octopus` and `Infrastructure` types — strong candidate should immediately recognize the parallel.

#### Layer 3 — mechanism (what should the candidate know about the tags?)

- **`yaml:"topic_name"`** — goccy/go-yaml decoder uses this for parsing
- **`validate:"required,min=1"`** — go-playground/validator v10 enforces non-empty + min length 1
- **`validate:"required,min=1,max=5"`** — ReplicationFactor must be 1-5; protects against typos like `30` (no Kafka cluster supports replication 30)
- **`yaml:"retention_hours,omitempty"`** — omit from YAML output if zero (relevant if they ever marshal back to YAML)
- **`validate:"omitempty,min=1"`** — `omitempty` here means "if absent, skip validation"; with min=1, it means "either absent OR ≥1"
- **`default:"24"`** — creasty/defaults sets `RetentionHours = 24` if unset after YAML parse

#### Layer 4 — where it goes

`internal/spec/spec.go`, alongside `Octopus`, `Infrastructure`, `Bucket` type declarations. NOT at the top of the file (the `Spec` struct should remain the lead type).

#### Layer 5 — what good looks like

Strong candidate:
- Opens `spec.go` first to see existing pattern
- Notices `Octopus` and `Bucket` are alongside `Spec`
- Places Kafka in the same neighborhood
- Doesn't break the package import ordering or formatting

Weak candidate:
- Pastes at the top of the file before `package spec`
- Pastes at the bottom after the function definitions
- Forgets to read existing structs first

#### Layer 6 — what to ask

| Probe | Strong | Weak |
|---|---|---|
| "Why `validate:"required,min=1"` on TopicName?" | "required = field must exist; min=1 = non-empty string" | "I don't know, it was in the snippet" |
| "Why max=5 on ReplicationFactor?" | "Sanity check — bigger than 5 is almost certainly a typo, no normal cluster runs that" | "It just happened to be there" |
| "What does `default:"24"` do?" | "Sets RetentionHours to 24 if YAML didn't specify; creasty/defaults handles this" | Doesn't know |
| "Where would you put this struct in spec.go?" | "After existing structs, before functions, alongside Octopus / Infrastructure" | "Anywhere?" |

---

### Snippet 2 — the new field on `Spec`

```go
Kafka *Kafka `yaml:"kafka,omitempty" validate:"omitempty"`
```

#### Layer 1 — what the candidate sees

A single struct-field line. They have to know it goes INSIDE the `Spec` struct definition.

#### Layer 2 — plain English

"Add this as a field on Spec. It's optional — pointer type means `nil` is a valid representation of 'no Kafka block in this spec'."

#### Layer 3 — mechanism (THE pointer-vs-value gate)

**This is the most important question of the exercise.** The struct is `*Kafka` not `Kafka`. Why?

- `*Kafka` means the field is a **pointer** — nil if absent, populated only if YAML includes a `kafka:` block
- `Kafka` (value type) would always be a zero-valued struct even when YAML has no `kafka:` block, AND validator would still run against it, AND `required` fields would fail

Combined with `validate:"omitempty"`:
- If `Kafka` is nil → validator skips the whole block
- If `Kafka` is non-nil → validator runs through its required fields

This is the **idiomatic Go pattern** for optional substructures. A senior knows this. A mid candidate copies it without understanding.

#### Layer 4 — where it goes

Inside the `Spec` struct definition in `spec.go`, alongside `Name`, `Octopus`, `Infrastructure`. Order matters for readability — usually after `Infrastructure`.

#### Layer 5 — what good looks like

Strong:
- Pastes inside the `Spec { }` block
- Asks unprompted: "Why pointer here?" (or explains it if asked)
- Notices the parallel with how `Bucket` is plural / `Octopus` is value (because Octopus is REQUIRED, not optional)

Weak:
- Pastes outside the Spec struct (e.g., at file scope) → won't compile
- Doesn't explain pointer semantics

#### Layer 6 — probes

| Probe | Strong | Weak |
|---|---|---|
| "Why is this `*Kafka` instead of `Kafka`?" | "Pointer lets nil represent 'absent'. Value type would always be present, even as zero, and required fields would fail validation" | "I'm not sure" |
| "Why is `Octopus` not a pointer but `Kafka` is?" | "Octopus is required; Kafka is optional. Pointer encodes optionality." | Doesn't see the distinction |
| "What happens at validation if Kafka is nil but you use Kafka (value) type instead?" | "Validator sees the zero struct and tries to validate required fields → error" | Doesn't reason through it |

---

### Snippet 3 — happy-path test

```go
func TestValidate_Kafka_Happy(t *testing.T) {
    s := &Spec{
        Name:    "demo",
        Octopus: Octopus{Space: "USXpress", Group: "platform"},
        Kafka: &Kafka{ ... },
    }
    require.NoError(t, Validate(s))
}
```

#### Layer 1 — what the candidate sees

A test function. Has to know it goes in `spec_test.go`.

#### Layer 2 — plain English

Standard happy-path test: build a valid spec, assert Validate returns no error.

#### Layer 3 — mechanism

- Uses `testify/require` (existing tests use this — strong candidate notices)
- Tests at the `Validate(*Spec)` boundary, not at decode boundary — same pattern as existing tests
- Includes valid values for all required fields including the new Kafka block

#### Layer 4 — where it goes

`internal/spec/spec_test.go` — same file as existing `TestValidate_HappyPath`, `TestValidate_MissingName`, etc. Add at bottom or grouped with other Kafka tests (the bad-partition one is Snippet 4).

#### Layer 5 — what good looks like

Strong:
- Opens spec_test.go BEFORE pasting — sees the imports + existing test conventions
- Notices `assert` + `require` are imported
- Pastes in the test file (not in spec.go)
- Runs `go test ./internal/spec/...` after pasting to verify

Weak:
- Pastes into spec.go (compiles but is weird)
- Doesn't run tests until both Snippet 3 + 4 are pasted (no incremental verification)

#### Layer 6 — probes

| Probe | Strong | Weak |
|---|---|---|
| "Where do tests for this package go?" | "internal/spec/spec_test.go — _test.go convention" | "Anywhere as long as same package" |
| "What does `require.NoError` do differently from `assert.NoError`?" | "require fails the test immediately + stops execution; assert continues" | Doesn't know |
| "After pasting Snippets 1+2+3, what command do you run?" | `go test ./internal/spec/...` | Doesn't think to test incrementally |

---

### Snippet 4 — negative test (bad partition count)

```go
func TestValidate_Kafka_BadPartition(t *testing.T) {
    s := &Spec{
        Name: "demo",
        Octopus: Octopus{...},
        Kafka: &Kafka{
            PartitionCount: 0,  // <-- the deliberate failure
            ...
        },
    }
    err := Validate(s)
    require.Error(t, err)
    assert.Contains(t, err.Error(), "PartitionCount")
}
```

#### Layer 1 — what the candidate sees

A test function that triggers a validation failure and asserts the error message names the field.

#### Layer 2 — plain English

Negative test: feed in invalid Kafka block (PartitionCount=0 fails `min=1`), assert Validate returns an error AND the error mentions "PartitionCount".

#### Layer 3 — mechanism

- `assert.Contains(t, err.Error(), "PartitionCount")` — the validator's error string SHOULD include the failing field name; this asserts that
- Uses `require.Error` to short-circuit if the error didn't fire at all
- Tests at the boundary; doesn't try to inspect the validator's internal structure

#### Layer 4 — where it goes

Same file as Snippet 3: `internal/spec/spec_test.go`. Alongside `TestValidate_Kafka_Happy`.

#### Layer 5 — what good looks like

Strong:
- Pastes alongside Snippet 3
- Runs `go test -v ./internal/spec/...` after — sees both Kafka tests appear in output
- Reads the error message format from the validator output to confirm "PartitionCount" really IS in there

Weak:
- Doesn't run tests, assumes it works
- Doesn't notice if test name conflicts with existing tests

#### Layer 6 — probes

| Probe | Strong | Weak |
|---|---|---|
| "Why does this test check that the error contains 'PartitionCount'?" | "We're verifying the error message tells you WHICH field failed — otherwise debugging is painful" | "Just to test something" |
| "What's the validator's error format?" | "Something like 'field X failed validation for tag Y' — field name is in there" | Doesn't know |
| "What if `assert.Contains` fails but `require.Error` passed?" | "Means the validation fired but error didn't mention the field — bug in validation library or wrong field name" | Doesn't reason through it |

---

### Snippet 5 — sample YAML

```yaml
kafka:
  topic_name: demo-events
  partition_count: 3
  replication_factor: 3
  retention_hours: 168
```

#### Layer 1 — what the candidate sees

A YAML block with 4 keys (snake_case names matching the YAML tags in Snippet 1).

#### Layer 2 — plain English

Update the sample YAML so the end-to-end demo (parse + validate) exercises the new Kafka block.

#### Layer 3 — mechanism

- **snake_case**: matches the `yaml:"topic_name"` tags in Snippet 1 (NOT `TopicName`)
- **valid values**: partition_count=3, replication_factor=3 are reasonable Kafka defaults
- **retention_hours: 168 = 7 days** — sane retention
- Goes alongside the existing `name`, `octopus`, `infrastructure` keys (top-level)

#### Layer 4 — where it goes

`hack/sample-spec.yaml`. Appended at the bottom (top-level key alongside `name:`, `octopus:`, `infrastructure:`).

#### Layer 5 — what good looks like

Strong:
- Opens sample-spec.yaml first to see existing structure
- Pastes at file scope (not indented under another key)
- Runs `go run main.go` (or equivalent) after pasting to demonstrate end-to-end
- Tests removing `retention_hours:` — confirms defaults fire and validation still passes

Weak:
- Pastes with wrong indentation (under another key)
- Doesn't test removing retention_hours
- Doesn't run main.go to demo end-to-end

#### Layer 6 — probes

| Probe | Strong | Weak |
|---|---|---|
| "Why snake_case in YAML but PascalCase in Go?" | "Go convention is PascalCase for exported fields; YAML tag maps PascalCase Go to snake_case YAML" | Doesn't see the distinction |
| "What happens if you remove `retention_hours:` from the YAML?" | "Defaults set it to 24; validation still passes" | "It fails" or doesn't know |
| "How would you demo this is working end-to-end?" | "Run main.go pointing at sample-spec.yaml; expect no error" | "Run the tests" (tests don't exercise the YAML decode path) |

---

## Candidate questions to expect (and how to redirect)

| Question | Strong-candidate framing | Weak-candidate framing | Your response |
|---|---|---|---|
| "Where does this code go?" | (Senior wouldn't ask — they'd find it) | Mid asks this | "Read the existing files — see where similar structures live" |
| "Should I run tests after each step?" | (Senior doesn't ask; just does it) | Asks for permission | "How would you know if your change broke something?" |
| "What test command should I run?" | (Senior tries `go test ./...` and reads the output) | Asks blindly | "Check the README or go.mod, see what conventions exist" |
| "Should I update the existing tests too?" | (Senior may ask — depends on if existing tests broke) | Mid asks because confused | If existing tests pass with their additions, leave alone. If they broke them, debug. |
| "What does `validate:dive` mean on the Buckets field?" | Strong: shows depth + curiosity | Mid wouldn't ask | "Tells validator to descend INTO the slice and validate each element" — bonus depth probe |
| "Why is Kafka a pointer?" | Strong asks; ready to discuss | Mid copies without understanding | Probe their understanding — see Layer 6 of Snippet 2 |
| "Do I need to update the README too?" | Strong asks; thinks beyond code | Mid wouldn't think of it | "Good instinct — not required for the exercise, but flag it as a follow-up" |
| "How do I import testify if it's not there?" | (Senior checks go.mod first) | Asks blindly | Existing tests already import it — read the imports |
| "What's the difference between `require` and `assert`?" | Strong knows | Mid doesn't | See Snippet 3 probes |
| "Can I just paste section F-H?" | Senior wouldn't ask | Mid checks for shortcuts | Tell them: the whole-file shortcuts were removed; they have to navigate |

## Things to look out for (red flags)

### 🚩 Hard fails

- **Doesn't open `spec.go` before pasting Snippet 1** — pasting without understanding the existing structure. Critical navigation failure.
- **Pastes Snippet 2 at file scope** (not inside `Spec` struct) — won't compile. Tells you they don't read context.
- **Pastes Snippet 1 (struct) in spec_test.go** — confuses code with test. Major navigation failure.
- **Doesn't run tests AT ALL during the exercise** — no verification discipline.
- **Doesn't realize Snippet 5 is YAML** — pastes it into a `.go` file. Severe carelessness.

### ⚠️ Yellow flags

- Runs all 5 snippets in 2 minutes without reading existing code — fast but shallow
- Doesn't run tests between Snippets 3 and 4 — incremental verification missing
- Doesn't run `main.go` to demonstrate end-to-end — only relies on `go test`
- Pastes Snippet 4 with `assert.Contains(t, err.Error(), "Kafka")` instead of "PartitionCount" because they didn't read the snippet carefully
- Forgets to check defaults behavior (removing retention_hours from YAML)

### 🟢 Green signals

- Opens EXERCISE.md, then opens spec.go before touching SNIPPETS.md
- Asks "should I read main.go first?" → curious about end-to-end flow
- Runs `go test ./...` (all tests) not just `./internal/spec/...` → comprehensive
- Volunteers explanation of `*Kafka` semantics without being asked
- Volunteers to remove `retention_hours` from YAML to test defaults
- Notices `validate:"dive"` on existing `Buckets` field and asks about it
- Asks about edge cases: "What if YAML has `partition_count: -1`?"

## Bonus depth probes (if they finish early)

If they fly through and you have spare minutes, ask:

1. **"How would you add a `min_in_sync_replicas` field that must be ≤ ReplicationFactor?"** — tests cross-field validation knowledge (validator has `ltefield`/`gtefield` tags)
2. **"What if a team wanted to declare 50 Kafka topics in one spec?"** — tests collection thinking; how would they refactor to `[]Kafka`?
3. **"How would you validate that TopicName matches a particular regex (e.g., `^[a-z][a-z0-9-]*$`)?"** — `validate:"regex=..."` or custom validator function
4. **"How does the defaults library decide what to set?"** — Reflection over struct tags, applied AFTER YAML unmarshal but BEFORE validation
5. **"What if we want to deprecate `retention_hours` in favor of `retention_duration`?"** — backward-compat thinking; aliasing in YAML tags

## Strong vs weak phrases (summary)

**STRONG**
- "Let me read spec.go first to see the existing pattern."
- "Pointer because nil = optional; value would always be present."
- "I'll run `go test -v ./internal/spec/...` to see what landed."
- "I noticed `validate:"dive"` on Buckets — that descends into the slice."
- "If I remove retention_hours from YAML, defaults should fire."
- "I'd structure the negative tests one per failure mode."

**WEAK / RED FLAG**
- "Where does this go?" (without trying to figure out first)
- "Can I just paste section F?" (post-tightening, that doesn't exist)
- "I'll run the tests at the end."
- "Why pointer?" said dismissively ("just is")
- Doesn't open existing files before pasting
- Forgets which file is `.go` vs `.yaml`

## Scoring rubric

| Tier | Signal |
|---|---|
| **STRONG hire** | Opens EXERCISE.md + spec.go BEFORE SNIPPETS.md. Navigates to right files unprompted. Pastes correctly. Runs tests incrementally. Explains `*Kafka` semantics. Demonstrates defaults via YAML modification. Volunteers questions about `validate:dive`, cross-field validation, etc. |
| **Hire** | Pastes correctly. Runs tests at end. Knows where files go after a brief scan. Can explain pointer/value when asked. Demonstrates end-to-end. |
| **Borderline** | Needs one nudge ("read the existing code first"). Pastes correctly but doesn't explain why. Mostly verifies but skips some steps. |
| **No hire** | Pastes Snippet 2 at file scope. Pastes Snippet 5 into a .go file. Doesn't run any tests. Can't explain `*Kafka`. Asks "where does this go?" repeatedly. |

## Time budget

- ~10-15 min total
- 2 min reading EXERCISE.md + skimming existing code
- 5-7 min pasting + verifying
- 3-5 min demo (end-to-end run, defaults check) + probes

If they're stuck on "where do I put this?" at minute 5, redirect: "Open spec.go and tell me what you see. Where would a new struct fit?"

If they finish all 5 + tests pass at minute 7, you have 8 min for depth probes — use them. That's where the senior signal lives.
