# Running the interview

Operational runbook for the Senior Platform Engineer round. The candidate works in **their own
codespace**, spawned from your personal GitHub copy of this repo; you watch over a Teams screen
share. It runs on their free Codespaces allowance (60 core-hours/month), so it costs us nothing and
they keep control of their machine.

---

## ⚠️ Before this repo goes anywhere

This lives on **personal GitHub**, not the corporate org, because external candidates need access
to it. Everything in it is therefore sanitised:

- No real hostnames, account numbers, client IDs, tenant IDs or secrets
- No USX/company names in exercises, evidence or sample data
- No real repository names or project identifiers

Every GUID, IP, domain and service name is invented. **If you add an exercise, keep it that way** —
copy the shape of a real incident, never its identifiers. Before pushing any change:

```bash
grep -rIniE 'usxpress|usx-|octopus\.usx|smfd|risingwave|variant-inc|\.usxpress\.' . \
  --exclude-dir=.git || echo "clean"
```

That must print `clean`.

---

## Pre-interview (~10 minutes before)

**1. Get their personal GitHub username.** Not an employer-tied account — Codespaces hours follow
the account, and they may lose access to a work account between rounds.

**2. Add them as a collaborator** (read-only):

```bash
gh api repos/<your-gh-user>/interview-senior-platform/collaborators/<their-username> \
  -X PUT -f permission=read
```

They get an email and a GitHub notification within about thirty seconds.

**3. Send the brief** — Teams or email, the day before if you can:

> Hi [name], for our technical round at [time]:
>
> 1. Check your email for an invitation to collaborate on
>    `<your-gh-user>/interview-senior-platform` → **Accept**
> 2. Go to https://github.com/<your-gh-user>/interview-senior-platform
> 3. **Code → Codespaces → Create codespace on main**
> 4. It takes about three minutes to build. Do this **before** we start if you can
> 5. When VS Code loads, open `README.md`
>
> You'll share your screen over Teams. Use Chrome, Edge or Firefox. There's nothing to prepare and
> nothing to revise — every exercise is a real problem from our production environment, and you can
> google anything you'd google at work.

**4. Spin up your own codespace and leave it running.** If theirs fails to build you can hand over
yours and lose two minutes instead of the round.

**5. Decide your Copilot policy and tell them at the start.** Allowing it is realistic and shows
whether they can supervise a suggestion. Disallowing it tests raw ability. Either is defensible;
changing your mind halfway through is not.

---

## During

**Confirm their environment first** — one minute, before the clock starts properly:

```bash
which go kubectl helm terraform jq
kubectl get nodes
kubectl -n sbx-missions get pods
cd exercises/01-go-spec-guard && go test ./...
```

Expected: five tools found, 2 nodes Ready, three pods in `sbx-missions` (two `Running`, one
`CreateContainerConfigError`), and the Go tests passing.

Then follow `.interviewer/INTERVIEWER_GUIDE.md`. Timings, model answers and the rubric are all
there.

| Min | Section |
|---|---|
| 0–5 | Greet, environment check, open README |
| 5–15 | Fixed verbal probes — **ask all five, in order, every time** |
| 15–40 | Exercise 01 (Go) |
| 40–58 | Exercise 02 or 03 |
| 58–70 | Exercise 04 |
| 70–75 | Their questions |

**Stay quiet for the first two or three minutes of each exercise.** How someone starts tells you
more than how they finish. After that, nudge freely — a candidate who uses a hint well is
demonstrating something real.

---

## After

1. **Score within four hours.** Fill the rubric while it's fresh; generosity grows overnight.
2. **Remove the collaborator:**
   ```bash
   gh api repos/<your-gh-user>/interview-senior-platform/collaborators/<their-username> -X DELETE
   ```
3. **Ask them to delete their codespace** at https://github.com/codespaces — it's their quota.
4. Add a line to the round's scorecard: the one thing you'd want on the team, and the one thing
   that would worry you in week one.

---

## Troubleshooting

**The codespace won't build.**
Have them open `/workspaces/.codespaces/.persistedshare/creation.log` and read the actual error.
If it's mid-interview, hand over yours rather than rebuilding.

**`kubectl -n sbx-missions get pods` shows nothing.**
`post-create.sh` didn't finish. Re-run it: `bash .devcontainer/post-create.sh`. It's idempotent and
takes about ninety seconds on a warm container.

**All three pods are Running — the Exercise 03 fault didn't apply.**
The patch step ran before the first rollout settled. Apply it by hand:

```bash
kubectl -n sbx-missions patch deploy sbx-missions-api --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/envFrom/-",
   "value":{"configMapRef":{"name":"sbx-missions-api-m-u"}}}
]'
```

**They already solved Exercise 03 and you want it back.**
```bash
kubectl -n sbx-missions delete cm sbx-missions-api-m-u --ignore-not-found
kubectl -n sbx-missions rollout restart deploy/sbx-missions-api
```

**`kubectl get nodes` shows a real cluster.**
You're in your own terminal, not the codespace. **Always check the context first:**

```bash
kubectl config current-context     # must read k3d-sandbox
```

Every object here is namespaced `sbx-missions` precisely so it cannot collide with a real
namespace, and `post-create.sh` refuses to run unless the context is `k3d-sandbox`. Neither
protects you from running a *solve* command by hand in the wrong terminal, so check first —
Exercise 03's answer involves deleting a ConfigMap, and that is not a command you want to get
wrong twice.

**Go tests fail with a module error.**
`cd exercises/01-go-spec-guard && go mod tidy`. The codespace has network; this only happens if the
post-create step was interrupted.

---

## Related

- [`.interviewer/INTERVIEWER_GUIDE.md`](.interviewer/INTERVIEWER_GUIDE.md) — probes, model answers, rubric
- [`SETUP.md`](SETUP.md) — publishing this repo and keeping it updated
- [`README.md`](README.md) — what the candidate sees
