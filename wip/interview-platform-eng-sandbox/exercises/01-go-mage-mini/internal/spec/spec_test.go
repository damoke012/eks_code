package spec

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Table tests for the existing fields. These should continue to pass after
// you add the Kafka block.

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
				{Reference: "", Prefix: "logs"}, // missing required field
			},
		},
	}
	require.Error(t, Validate(s))
}

// TODO (interview): add test cases here for your Kafka block.
//
// At minimum:
//   1. A test that builds a valid Kafka spec and expects no error from Validate.
//   2. A test where partition_count = 0 and expects a clear validation error.
//
// Bonus:
//   3. A table test that covers replication_factor edge cases (0, 1, 5, 6).
//   4. A test that ParseFile correctly applies the default retention_hours = 24
//      when the YAML omits it.
