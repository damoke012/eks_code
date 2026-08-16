# Publishing and maintaining this repo

There are **two** repos and they must not be merged:

| | Contents | Who sees it |
|---|---|---|
| `interview-senior-platform` (candidate) | `README.md`, `exercises/`, `.devcontainer/`, `.gitignore` | the candidate, as a read-only collaborator |
| `interview-senior-platform-private` | this file, `INTERVIEWER_GUIDE.md`, `CANDIDATE-WORKFLOW.md`, `recreate.sh`, `ex01-solved/` | you |

Both live on **personal** GitHub and are kept in sync from `wip/` by hand — deliberately, so that
nothing corporate can be pushed by accident.

⚠️ The interviewer guide was previously shipped inside the candidate repo under `.interviewer/`,
hidden by a `files.exclude` setting in `devcontainer.json`. That is not a control: `cat
.interviewer/INTERVIEWER_GUIDE.md` defeats it, and the candidate can read the repo on github.com
anyway. Model answers and the rubric live in the private repo now. Keep it that way.

## First publish

```bash
# 1. sanitisation check — must print "clean"
grep -rIniE 'usxpress|usx-|octopus\.usx|smfd|risingwave|variant-inc|\.usxpress\.' . \
  --exclude-dir=.git || echo "clean"

# 2. create the repo on your PERSONAL account, private
gh repo create <your-gh-user>/interview-senior-platform --private \
  --description "Technical interview environment — senior platform engineer"

# 3. push
git init && git add . && git commit -m "interview: senior platform engineer round"
git branch -M main
git remote add origin git@github.com:<your-gh-user>/interview-senior-platform.git
git push -u origin main
```

⚠️ Use your **personal** GitHub credentials for this remote. Do not reuse a corporate token.

## Updating it later

```bash
cd /path/to/interview-senior-platform
rsync -a --delete \
  --exclude='.git' \
  /path/to/platform-repo/wip/interview-senior-platform-2026-08/ .

# leak check — BOTH must print "clean"
grep -rIniE 'usxpress|usx-|octopus\.usx|smfd|risingwave|variant-inc|\.usxpress\.|vibin' . \
  --exclude-dir=.git || echo "clean"
ls -a | grep -E 'INTERVIEWER_GUIDE|CANDIDATE-WORKFLOW|SETUP\.md|recreate\.sh|ex01-solved|\.interviewer' \
  || echo "clean"

# then commit and push
```

## Verifying a change before an interview

Always build a fresh codespace after changing `.devcontainer/` or the exercises — the failure mode
is a broken build five minutes before a candidate joins.

```bash
kubectl get nodes                                  # 2 Ready
kubectl -n sbx-missions get pods                       # 2 Running, 1 CreateContainerConfigError
cd exercises/01-go-spec-guard && go test ./...     # ok
go run . hack/ui-spec.yaml                         # must exit 0 BEFORE the candidate fixes it
```

That last one is the exercise's whole premise. If it starts failing, someone has solved Exercise 01
in the template.

## Adding an exercise

Keep the pattern:

- Built from a **real incident**, with every identifier replaced
- `EXERCISE.md` states the time, the task, and *what we're watching for* — candidates deserve to
  know the criteria
- Model answers and grading go in **this private repo**, never in the candidate repo
- Re-run the sanitisation grep before pushing
