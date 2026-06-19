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

	// TODO (interview): add a `Kafka *Kafka` field here once you've defined
	// the Kafka struct below. Use a pointer so omitting the block remains
	// distinguishable from an empty block.
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

// TODO (interview): define your Kafka struct here. See EXERCISE.md for the
// fields and constraints. Mirror the validator + defaults patterns above.

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
