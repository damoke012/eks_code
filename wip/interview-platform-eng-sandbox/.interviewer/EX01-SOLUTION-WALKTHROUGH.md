# Exercise 01 — Step-by-step solution walkthrough

**Purpose**: For the interviewer to practice running the candidate's flow end-to-end so they know what success looks like. **Do NOT share with candidates.**

Estimated time: 10-12 min if you know what you're doing. Senior candidates: 12-18 min. Mid: 20-25 min.

---

## Setup — open the right files in tabs (~30 sec)

In the codespace file tree, click these to open each in its own tab:

1. `exercises/01-go-mage-mini/EXERCISE.md`
2. `exercises/01-go-mage-mini/SNIPPETS.md` — right-click tab → **Open Preview** for rendered view
3. `exercises/01-go-mage-mini/internal/spec/spec.go`
4. `exercises/01-go-mage-mini/internal/spec/spec_test.go`
5. `exercises/01-go-mage-mini/hack/sample-spec.yaml`

Open the terminal (Ctrl+`) and cd to the exercise dir:

```bash
cd /workspaces/interview-platform-eng-sandbox/exercises/01-go-mage-mini
```

---

## Step 1 — Baseline test (30 sec)

```bash
go test ./...
```

**Expected**: `ok mage-mini/internal/spec` — 4 existing tests pass. If failure, run `go mod tidy` first.

---

## Step 2 — Add the Kafka struct to spec.go (2 min)

Open `spec.go`. Find this line (around line 48):

```
// TODO (interview): define your Kafka struct here. See EXERCISE.md for the
// fields and constraints. Mirror the validator + defaults patterns above.
```

**Copy from SNIPPETS.md — Block A**:

```go
// Kafka configures the topic this app produces or consumes from.
type Kafka struct {
	TopicName         string `yaml:"topic_name" validate:"required,min=1"`
	PartitionCount    int    `yaml:"partition_count" validate:"required,min=1"`
	ReplicationFactor int    `yaml:"replication_factor" validate:"required,min=1,max=5"`
	RetentionHours    int    `yaml:"retention_hours,omitempty" validate:"omitempty,min=1" default:"24"`
}
```

**Paste**: Replace those two TODO comment lines with the block above. The result should be: `Kafka` struct definition sitting BETWEEN the `Bucket` struct and the `ParseFile` function.

---

## Step 3 — Add the Kafka field to the Spec struct (1 min)

Stay in `spec.go`. Scroll up to the `Spec` struct (around line 21). Find:

```
// TODO (interview): add a `Kafka *Kafka` field here once you've defined
// the Kafka struct below. Use a pointer so omitting the block remains
// distinguishable from an empty block.
```

**Copy from SNIPPETS.md — Block B**:

```go
Kafka *Kafka `yaml:"kafka,omitempty" validate:"omitempty"`
```

**Paste**: Replace those three TODO comment lines with the single line above. The result: `Spec` struct now has 4 fields (Name, Octopus, Infrastructure, Kafka).

**Save the file** (Ctrl+S).

---

## Step 4 — Verify existing tests still pass (30 sec)

```bash
go test ./...
```

**Expected**: still 4 tests pass. If compile error, you have a typo — check that:
- Kafka struct is OUTSIDE the Spec struct (separate top-level `type Kafka struct {...}`)
- Spec struct field uses `*Kafka` (pointer with asterisk)

---

## Step 5 — Add the happy-path test to spec_test.go (2 min)

Open `spec_test.go`. Find the TODO comments at the bottom (around line 58):

```
// TODO (interview): add test cases here for your Kafka block.
//
// At minimum: ...
```

**Copy from SNIPPETS.md — Block C**:

```go
func TestValidate_Kafka_Happy(t *testing.T) {
	s := &Spec{
		Name:    "demo",
		Octopus: Octopus{Space: "USXpress", Group: "platform"},
		Kafka: &Kafka{
			TopicName:         "demo-events",
			PartitionCount:    3,
			ReplicationFactor: 3,
			RetentionHours:    168,
		},
	}
	require.NoError(t, Validate(s))
}
```

**Paste**: After the closing `}` of `TestValidate_BucketDive` and after the TODO comments. (Comments can stay; just add the function below them.)

---

## Step 6 — Add the negative test (1 min)

Stay in `spec_test.go`. Below the function you just added, **copy from SNIPPETS.md — Block D**:

```go
func TestValidate_Kafka_BadPartition(t *testing.T) {
	s := &Spec{
		Name:    "demo",
		Octopus: Octopus{Space: "USXpress", Group: "platform"},
		Kafka: &Kafka{
			TopicName:         "demo",
			PartitionCount:    0,
			ReplicationFactor: 3,
		},
	}
	err := Validate(s)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "PartitionCount")
}
```

**Paste**: After the closing `}` of the happy test you just added.

**Save the file** (Ctrl+S).

---

## Step 7 — Run all tests (30 sec)

```bash
go test -v ./...
```

**Expected output**:
```
=== RUN   TestValidate_HappyPath
--- PASS: TestValidate_HappyPath (0.00s)
=== RUN   TestValidate_MissingName
--- PASS: TestValidate_MissingName (0.00s)
=== RUN   TestValidate_NameTooLong
--- PASS: TestValidate_NameTooLong (0.00s)
=== RUN   TestValidate_BucketDive
--- PASS: TestValidate_BucketDive (0.00s)
=== RUN   TestValidate_Kafka_Happy
--- PASS: TestValidate_Kafka_Happy (0.00s)
=== RUN   TestValidate_Kafka_BadPartition
--- PASS: TestValidate_Kafka_BadPartition (0.00s)
PASS
ok      mage-mini/internal/spec
```

**6 tests, all PASS.** If anything fails, look at the failure message and check your code.

---

## Step 8 — Update sample-spec.yaml (1 min)

Open `hack/sample-spec.yaml`. Find the commented Kafka block at the bottom:

```
# TODO (interview): add a `kafka:` block here. Use it to manually verify your
# new struct + validator behavior:
#
# kafka:
#   topic_name: demo-events
#   partition_count: 3
#   replication_factor: 3
#   retention_hours: 168
```

**Copy from SNIPPETS.md — Block E**:

```yaml
kafka:
  topic_name: demo-events
  partition_count: 3
  replication_factor: 3
  retention_hours: 168
```

**Paste**: Below the existing content. You can either delete the commented block above or leave it — doesn't matter. The key is having an UNCOMMENTED `kafka:` block at the bottom.

**Save the file** (Ctrl+S).

---

## Step 9 — Smoke test the CLI end-to-end (30 sec)

```bash
go run . hack/sample-spec.yaml
```

**Expected output**:
```
spec valid: name=demo-service octopus.space=USXpress
```

That's the win condition. If you see an error, your YAML or struct doesn't line up.

---

## Step 10 (BONUS) — Prove defaults work (1 min)

This shows senior-level understanding. Demonstrates the `default:"24"` tag on `RetentionHours` actually does something.

In `hack/sample-spec.yaml`, comment out or delete the `retention_hours` line:

```yaml
kafka:
  topic_name: demo-events
  partition_count: 3
  replication_factor: 3
  # retention_hours: 168    <-- removed/commented
```

Re-run:

```bash
go run . hack/sample-spec.yaml
```

**Expected**: still says `spec valid: ...` — even though retention_hours was omitted, the default of 24 was applied by `defaults.Set()` before validation ran. **This proves defaults work**.

---

## What "done" looks like

You should be able to demonstrate all three:

1. ✓ `go test ./...` shows 6 tests passing
2. ✓ `go run . hack/sample-spec.yaml` outputs "spec valid: ..."
3. ✓ Removing `retention_hours` from YAML still produces "spec valid: ..." (defaults work)

That's a complete Exercise 01 solution. Total time if you're moving deliberately: ~10 min.

---

## Common mistakes a candidate might make

- **Forgets to save files** — VS Code auto-saves are off by default; press Ctrl+S after each edit
- **Adds Kafka struct INSIDE Spec struct** — Go won't compile (illegal nested type declaration)
- **Uses `Kafka Kafka` (value) instead of `Kafka *Kafka` (pointer)** — tests still pass but loses the "omitted vs empty" signal a senior would want
- **Doesn't run `go mod tidy`** when adding new imports — wouldn't apply here since we use existing imports
- **Pastes Block C/D before defining Kafka struct** — Go's compilation requires the type to exist before tests reference it (though usually fine due to package-level resolution)

---

## When done, reset before the next interview

```bash
cd /workspaces/interview-platform-eng-sandbox/exercises/01-go-mage-mini
git checkout -- internal/spec/spec.go internal/spec/spec_test.go hack/sample-spec.yaml
```

That restores the starter state.
