// Package spec loads and validates deploy manifests.
//
// A manifest describes how one application is deployed: where it lives in the
// deployment tool, what port it listens on, and — for browser applications —
// what configuration is baked into the served bundle.
package spec

import (
	"errors"
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// Spec is the root of a deploy manifest.
type Spec struct {
	Name    string  `yaml:"name"`
	Octopus Octopus `yaml:"octopus"`
	Service Service `yaml:"service"`

	// UI is present only for browser applications (single page apps).
	UI *UI `yaml:"ui,omitempty"`
}

// Octopus describes where the project lives in the deployment tool.
type Octopus struct {
	Space string `yaml:"space"`
	Group string `yaml:"group"`
}

// Service describes the container port the application listens on.
type Service struct {
	TargetPort int `yaml:"targetPort"`
}

// UI describes a browser application.
type UI struct {
	// Type is "spa" for single page applications.
	Type string `yaml:"type"`

	// ConfigVars are written verbatim into a ConfigMap and served to the
	// browser as runtime configuration.
	ConfigVars map[string]string `yaml:"configVars"`
}

// Load reads and parses a manifest from disk.
func Load(path string) (*Spec, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}

	var s Spec
	if err := yaml.Unmarshal(raw, &s); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	return &s, nil
}

// Validate reports every problem it finds, not just the first one. Callers get
// a single joined error so a developer can fix everything in one pass.
func Validate(s *Spec) error {
	if s == nil {
		return errors.New("spec is nil")
	}

	var problems []error

	if s.Name == "" {
		problems = append(problems, errors.New("name: must not be empty"))
	}
	if s.Octopus.Space == "" {
		problems = append(problems, errors.New("octopus.space: must not be empty"))
	}
	if s.Octopus.Group == "" {
		problems = append(problems, errors.New("octopus.group: must not be empty"))
	}
	if s.Service.TargetPort < 1 || s.Service.TargetPort > 65535 {
		problems = append(problems,
			fmt.Errorf("service.targetPort: %d is not a valid port", s.Service.TargetPort))
	}

	if s.UI != nil {
		problems = append(problems, validateUI(s.UI)...)
	}

	return errors.Join(problems...)
}

func validateUI(ui *UI) []error {
	var problems []error

	if ui.Type != "spa" {
		problems = append(problems,
			fmt.Errorf("ui.type: %q is not a supported ui type", ui.Type))
	}

	// TODO(exercise): see EXERCISE.md.

	return problems
}
