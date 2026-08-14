# Solutions — do not publish

Working solutions for `wip/interview-senior-platform-2026-08/`. This directory must
**never** be copied into the personal-GitHub repo the candidate can see.

- `ex01-solved/` — `spec.go` and `spec_test.go` with the identity rule implemented.
  Verified: existing 4 tests pass, 7 new table cases pass, `hack/ui-spec.yaml` exits 1
  flagging `VITE_AUTH_CLIENT_ID` and `VITE_TASK_API_SCOPES`, and correctly *not*
  flagging `VITE_AUTH_TENANT_ID`.

To restore a solved copy for a dry run:

    cp -r wip/interview-senior-platform-2026-08/exercises/01-go-spec-guard /tmp/solve
    cp wip/interview-senior-platform-2026-08-private/ex01-solved/*.go /tmp/solve/internal/spec/
    cd /tmp/solve && go test ./... && go run . hack/ui-spec.yaml
