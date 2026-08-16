# Interviewer material — never publish to the candidate repo

Everything the interviewer needs for the Senior Platform Engineer round. It is deliberately kept
out of `interview-senior-platform`, the repo the candidate is given read access to.

This directory is published as its own private repo, `interview-senior-platform-private`, so it can
be cloned into your interviewer codespace rather than pasted in.

| File | What it is |
|---|---|
| `INTERVIEWER_GUIDE.md` | Verbal probes, model answers for every exercise, scoring rubric |
| `CANDIDATE-WORKFLOW.md` | Running the round: invite, brief, timings, troubleshooting |
| `SETUP.md` | Publishing and syncing both repos |
| `DRY-RUN.md` | 26-step walkthrough of the whole environment |
| `recreate.sh` | Demo that opens Exercise 01 by showing the outage |
| `fix.awk` | Applies the Exercise 01 model answer in one command |
| `ex01-solved/` | `spec.go` and `spec_test.go` with the identity rule implemented |

## Why the separation exists

The interviewer guide originally shipped inside the candidate repo under `.interviewer/`, hidden by
a `files.exclude` setting in `devcontainer.json`. That is not a control — `cat
.interviewer/INTERVIEWER_GUIDE.md` defeats it, and a collaborator can read the repo on github.com
regardless. Model answers, the rubric and the hire bar were all readable by any candidate who
looked.

Keep it that way: nothing in here goes into the candidate repo.

## Using it during a round

Clone this beside the candidate repo in **your own** codespace:

```bash
git clone git@github.com:<your-gh-user>/interview-senior-platform-private.git \
  /workspaces/interview-private
```

**Open Exercise 01 by showing the failure** (~30 seconds, read-only, your screen only):

```bash
cd /workspaces/interview-senior-platform/exercises/01-go-spec-guard
/workspaces/interview-private/recreate.sh "$PWD/hack/ui-spec.yaml"
```

Never run it in the candidate's codespace — steps 5 to 7 are Exercise 02's answer.

**Show the Exercise 01 model answer**, if you want to at the end of a round:

```bash
cd /workspaces/interview-senior-platform/exercises/01-go-spec-guard
awk -f /workspaces/interview-private/fix.awk internal/spec/spec.go > /tmp/s.go \
  && mv /tmp/s.go internal/spec/spec.go
go test ./... && go run . hack/ui-spec.yaml   # exits 1, flags 2 keys, spares TENANT_ID
git checkout internal/spec/spec.go            # reset
```

## Verified

Exercise 01 bug intact (`exit=0`) and fix correct (`exit=1`, two keys flagged, `VITE_AUTH_TENANT_ID`
not flagged); Exercise 03 fault deploys and recovers from Terraform state; `recreate.sh` runs clean
on a fresh codespace. Confirmed 2026-08-16 against a codespace built from the published repo.
