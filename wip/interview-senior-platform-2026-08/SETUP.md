# Publishing and maintaining this repo

This template lives in `wip/` in the platform repo (corporate) and is **published to personal
GitHub** so external candidates can use it. The two copies are kept in sync by hand — deliberately,
so that nothing corporate can be pushed by accident.

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
# re-run the sanitisation check, then commit and push
```

## Verifying a change before an interview

Always build a fresh codespace after changing `.devcontainer/` or the exercises — the failure mode
is a broken build five minutes before a candidate joins.

```bash
kubectl get nodes                                  # 2 Ready
kubectl -n missions get pods                       # 2 Running, 1 CreateContainerConfigError
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
- Model answers and grading go in `.interviewer/`, never in the exercise
- Re-run the sanitisation grep before pushing
