// Package spec loads and validates deploy manifests.
//
// A manifest describes how one application is deployed: where it lives in the
// deployment tool, what port it listens on, and — for browser applications —
// what configuration is baked into the served bundle.
package spec

import (
	"errors"
	"fmt"
	"maps"
	"os"
	"regexp"
	"slices"
	"strings"

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

	for _, key := range slices.Sorted(maps.Keys(ui.ConfigVars)) {
		if !identityKey(key) {
			continue
		}
		if !identityValue(ui.ConfigVars[key]) {
			continue
		}
		problems = append(problems, fmt.Errorf(
			"ui.configVars.%s: application identity must not be hardcoded here. "+
				"The platform generates this value on every deploy; remove the key and "+
				"read it from the configuration the platform serves at runtime", key))
	}

	return problems
}

// guidRE matches a bare identity, optionally carrying a scope suffix such as
// "<guid>/.default" or "<guid>/user_impersonation".
var guidRE = regexp.MustCompile(
	`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(/[A-Za-z._]+)?$`)

// identityValue reports whether v has the shape of an identity we generate.
func identityValue(v string) bool { return guidRE.MatchString(v) }

// identityKey reports whether a config key names something the platform owns.
//
// TENANT_ID is deliberately absent: a tenant identifier is constant for the
// whole organisation and does not change when an app registration is recreated,
// so pinning it is harmless.
var identitySuffixes = []string{"CLIENT_ID", "APP_ID", "SCOPES", "AUDIENCE"}

func identityKey(k string) bool {
	up := strings.ToUpper(k)
	for _, suffix := range identitySuffixes {
		if strings.HasSuffix(up, suffix) {
			return true
		}
	}
	return false
}
