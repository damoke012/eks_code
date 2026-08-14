package spec

import (
	"strings"
	"testing"
)

func validSpec() *Spec {
	return &Spec{
		Name:    "orders-api",
		Octopus: Octopus{Space: "Acme", Group: "orders"},
		Service: Service{TargetPort: 8080},
	}
}

func TestValidate_Happy(t *testing.T) {
	if err := Validate(validSpec()); err != nil {
		t.Fatalf("expected valid spec, got: %v", err)
	}
}

func TestValidate_MissingFields(t *testing.T) {
	tests := []struct {
		name    string
		mutate  func(*Spec)
		wantSub string
	}{
		{"no name", func(s *Spec) { s.Name = "" }, "name"},
		{"no space", func(s *Spec) { s.Octopus.Space = "" }, "octopus.space"},
		{"no group", func(s *Spec) { s.Octopus.Group = "" }, "octopus.group"},
		{"bad port", func(s *Spec) { s.Service.TargetPort = 0 }, "service.targetPort"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s := validSpec()
			tc.mutate(s)

			err := Validate(s)
			if err == nil {
				t.Fatalf("expected an error mentioning %q, got nil", tc.wantSub)
			}
			if !strings.Contains(err.Error(), tc.wantSub) {
				t.Fatalf("expected error mentioning %q, got: %v", tc.wantSub, err)
			}
		})
	}
}

func TestValidate_ReportsEveryProblem(t *testing.T) {
	s := &Spec{} // everything wrong at once

	err := Validate(s)
	if err == nil {
		t.Fatal("expected errors, got nil")
	}

	for _, want := range []string{"name", "octopus.space", "octopus.group", "service.targetPort"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("expected the joined error to mention %q, got: %v", want, err)
		}
	}
}

func TestValidate_UIType(t *testing.T) {
	s := validSpec()
	s.UI = &UI{Type: "server-rendered"}

	err := Validate(s)
	if err == nil || !strings.Contains(err.Error(), "ui.type") {
		t.Fatalf("expected a ui.type error, got: %v", err)
	}
}

func TestValidate_UIRejectsHardcodedIdentity(t *testing.T) {
	tests := []struct {
		name       string
		configVars map[string]string
		wantErr    bool
	}{
		{"client id pinned", map[string]string{
			"VITE_AUTH_CLIENT_ID": "4f1c8a92-77b3-4e50-9a61-0c2de5b71f38"}, true},
		{"sibling scope pinned", map[string]string{
			"VITE_TASK_API_SCOPES": "6a90d3f5-1b27-4c88-9e4f-3d05b7a26c41/.default"}, true},
		{"delegated scope suffix", map[string]string{
			"VITE_TASK_API_SCOPES": "6a90d3f5-1b27-4c88-9e4f-3d05b7a26c41/user_impersonation"}, true},
		{"tenant id is safe", map[string]string{
			"VITE_AUTH_TENANT_ID": "8d2b6e14-59af-42c7-b0d3-71e4a9c58260"}, false},
		{"a url is not an identity", map[string]string{
			"VITE_API_GATEWAY": "https://api.orders.example.internal/v1/"}, false},
		{"a guid under an unrelated key", map[string]string{
			"VITE_EXPERIMENT_BUCKET": "4f1c8a92-77b3-4e50-9a61-0c2de5b71f38"}, false},
		{"no config at all", map[string]string{}, false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s := validSpec()
			s.UI = &UI{Type: "spa", ConfigVars: tc.configVars}

			err := Validate(s)
			if tc.wantErr && err == nil {
				t.Fatalf("expected a rejection, got nil")
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("expected no error, got: %v", err)
			}
		})
	}
}
