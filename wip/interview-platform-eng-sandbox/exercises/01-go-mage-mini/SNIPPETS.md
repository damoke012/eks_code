# Exercise 01 — Complete Code Cheat Sheet

You can use this two ways:

- **Block-by-block** (sections A-E below) — figure out where each block goes inside the existing files
- **Whole-file paste** (sections F-H below) — just replace the existing file with the final version

Either way works. Pick what's faster for you.

**What's STILL on you** — and what we're scoring:

- Which file each block belongs in (if you pick block-by-block)
- The commands to run after each step to verify your work
- Reading the existing code to understand WHY each block exists where it does
- Demonstrating the end-to-end flow works

You can paste anything below verbatim. Nothing is a trick.

---

## A — The new Kafka struct

```go
// Kafka configures the topic this app produces or consumes from.
type Kafka struct {
	TopicName         string `yaml:"topic_name" validate:"required,min=1"`
	PartitionCount    int    `yaml:"partition_count" validate:"required,min=1"`
	ReplicationFactor int    `yaml:"replication_factor" validate:"required,min=1,max=5"`
	RetentionHours    int    `yaml:"retention_hours,omitempty" validate:"omitempty,min=1" default:"24"`
}
```

## B — The new field on `Spec`

```go
Kafka *Kafka `yaml:"kafka,omitempty" validate:"omitempty"`
```

> Hint to yourself: why pointer and not value? What does it let you express?

## C — Happy-path test

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

## D — Negative test (bad partition count)

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

## E — YAML addition for the sample spec

```yaml
kafka:
  topic_name: demo-events
  partition_count: 3
  replication_factor: 3
  retention_hours: 168
```

---

# Or — paste the whole-file versions

Use these if you'd rather just overwrite the existing files than navigate to specific lines.

## F — Complete `internal/spec/spec.go`

```go
// Package spec parses and validates a deployment spec YAML.
//
// The existing pattern uses:
//   - goccy/go-yaml for parsing
//   - go-playground/validator for declarative field-level validation
//   - creasty/defaults for default values on optional fields
//
// Extend this file to add a new top-level Kafka block per the EXERCISE.md.
package spec

import (
	"fmt"
	"os"

	"github.com/creasty/defaults"
	"github.com/go-playground/validator/v10"
	"github.com/goccy/go-yaml"
)

// Spec is the top-level deployment spec a team writes per service.
type Spec struct {
	Name           string         `yaml:"name" validate:"required,min=1,max=63"`
	Octopus        Octopus        `yaml:"octopus" validate:"required"`
	Infrastructure Infrastructure `yaml:"infrastructure,omitempty"`
	Kafka          *Kafka         `yaml:"kafka,omitempty" validate:"omitempty"`
}

// Octopus configures where this app deploys.
type Octopus struct {
	Space string `yaml:"space" validate:"required"`
	Group string `yaml:"group" validate:"required"`
}

// Infrastructure groups optional cloud resources a spec can request.
type Infrastructure struct {
	Buckets []Bucket `yaml:"buckets,omitempty" validate:"dive"`
}

// Bucket is one S3 bucket the deploy should provision.
type Bucket struct {
	Reference string `yaml:"reference" validate:"required"`
	Prefix    string `yaml:"prefix,omitempty"`
}

// Kafka configures the topic this app produces or consumes from.
type Kafka struct {
	TopicName         string `yaml:"topic_name" validate:"required,min=1"`
	PartitionCount    int    `yaml:"partition_count" validate:"required,min=1"`
	ReplicationFactor int    `yaml:"replication_factor" validate:"required,min=1,max=5"`
	RetentionHours    int    `yaml:"retention_hours,omitempty" validate:"omitempty,min=1" default:"24"`
}

// ParseFile reads a YAML file from disk and decodes it into a Spec.
// Defaults are applied before return.
func ParseFile(path string) (*Spec, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}

	s := &Spec{}
	if err := yaml.Unmarshal(b, s); err != nil {
		return nil, fmt.Errorf("unmarshal %s: %w", path, err)
	}

	if err := defaults.Set(s); err != nil {
		return nil, fmt.Errorf("apply defaults: %w", err)
	}

	return s, nil
}

// Validate runs declarative struct validation and returns any errors as a
// single wrapped error.
func Validate(s *Spec) error {
	v := validator.New(validator.WithRequiredStructEnabled())

	if err := v.Struct(s); err != nil {
		return fmt.Errorf("spec invalid: %w", err)
	}

	return nil
}
```

## G — Complete `internal/spec/spec_test.go`

```go
package spec

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestValidate_HappyPath(t *testing.T) {
	s := &Spec{
		Name: "demo-service",
		Octopus: Octopus{
			Space: "USXpress",
			Group: "platform",
		},
	}
	require.NoError(t, Validate(s))
}

func TestValidate_MissingName(t *testing.T) {
	s := &Spec{
		Octopus: Octopus{Space: "USXpress", Group: "platform"},
	}
	err := Validate(s)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "Name")
}

func TestValidate_NameTooLong(t *testing.T) {
	long := ""
	for range 80 {
		long += "x"
	}
	s := &Spec{
		Name:    long,
		Octopus: Octopus{Space: "USXpress", Group: "platform"},
	}
	require.Error(t, Validate(s))
}

func TestValidate_BucketDive(t *testing.T) {
	s := &Spec{
		Name:    "demo-service",
		Octopus: Octopus{Space: "USXpress", Group: "platform"},
		Infrastructure: Infrastructure{
			Buckets: []Bucket{
				{Reference: "", Prefix: "logs"},
			},
		},
	}
	require.Error(t, Validate(s))
}

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

## H — Complete `hack/sample-spec.yaml`

```yaml
name: demo-service
octopus:
  space: USXpress
  group: platform
infrastructure:
  buckets:
    - reference: logs
      prefix: app-logs
    - reference: events
kafka:
  topic_name: demo-events
  partition_count: 3
  replication_factor: 3
  retention_hours: 168
```

---

## When you think you're done

You should be able to demonstrate:

1. All tests pass (existing + new) — run the right command in the right directory
2. The sample spec parses + validates end-to-end without error
3. If you remove `retention_hours` from the YAML, the spec still validates (defaults work)

If you can't show those three things, you're not done yet. Walk through your code with us and we'll figure out what's missing together.
