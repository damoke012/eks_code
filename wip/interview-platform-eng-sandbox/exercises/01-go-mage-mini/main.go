// mage-mini is a simplified version of the production tool that reads a
// deployment spec YAML and validates it. The real one orchestrates Octopus +
// Terraform + Kubernetes; this version only does the parse+validate step.
//
// Usage:
//
//	go run . path/to/spec.yaml
package main

import (
	"fmt"
	"os"

	"mage-mini/internal/spec"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: mage-mini <path-to-spec.yaml>")
		os.Exit(2)
	}

	s, err := spec.ParseFile(os.Args[1])
	if err != nil {
		fmt.Fprintf(os.Stderr, "parse error: %v\n", err)
		os.Exit(1)
	}

	if err := spec.Validate(s); err != nil {
		fmt.Fprintf(os.Stderr, "validation error: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("spec valid: name=%s octopus.space=%s\n", s.Name, s.Octopus.Space)
}
