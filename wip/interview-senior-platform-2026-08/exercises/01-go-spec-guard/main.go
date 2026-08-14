// Command specguard validates a deploy manifest before it reaches the cluster.
package main

import (
	"fmt"
	"os"

	"specguard/internal/spec"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: specguard <spec.yaml>")
		os.Exit(2)
	}

	s, err := spec.Load(os.Args[1])
	if err != nil {
		fmt.Fprintf(os.Stderr, "load: %v\n", err)
		os.Exit(1)
	}

	if err := spec.Validate(s); err != nil {
		fmt.Fprintf(os.Stderr, "spec invalid:\n%v\n", err)
		os.Exit(1)
	}

	fmt.Printf("spec valid: %s (%s/%s)\n", s.Name, s.Octopus.Space, s.Octopus.Group)
}
