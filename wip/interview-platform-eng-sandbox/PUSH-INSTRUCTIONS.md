# How to publish this sandbox + run the first interview

## One-time setup

### 1. Create the GitHub repo (private, in variant-inc org)

```bash
# from WSL2 with gh CLI authenticated as a variant-inc member
gh repo create variant-inc/interview-platform-eng-sandbox \
  --private \
  --description "Hands-on interview environment for cloud platform engineer candidates"
```

### 2. Push this directory as the initial commit

```bash
cd /path/to/wip/interview-platform-eng-sandbox
git init
git add .
git commit -m "feat: interview sandbox v1 (Go + K8s + AWS + TF + SLO exercises)"
git branch -M main
git remote add origin git@github.com:variant-inc/interview-platform-eng-sandbox.git
git push -u origin main
```

### 3. Enable Codespaces for the repo

GitHub.com → repo → Settings → Codespaces → Allow `Org members`

If you want candidate-spawned codespaces too (they need to be a collaborator):
- Add `Codespaces user permissions` → set the candidate as Outside Collaborator with `Read` access
- They can then click "Code → Codespaces → Create codespace" themselves

### 4. AWS account integration

Follow [`.interviewer/AWS_INTEGRATION.md`](.interviewer/AWS_INTEGRATION.md) to:
- Create the `interview-sandbox-readonly` role in `infra-playground`
- Pre-create the fake SM secret
- Set Codespaces Secrets if needed

### 5. Validate end-to-end

```bash
# As yourself, create a codespace
gh codespace create -R variant-inc/interview-platform-eng-sandbox

# Wait ~3 min for post-create.sh to finish
# Then verify
gh codespace ssh -c <codespace-name>
# Inside:
kubectl get nodes
kubectl -n broken get pods
cd exercises/01-go-mage-mini && go test ./...
```

If all pass, you're ready.

## Per-interview workflow

### 10 minutes before

1. Create a fresh codespace for THIS candidate:
   ```bash
   gh codespace create -R variant-inc/interview-platform-eng-sandbox --display-name "interview-tommy-$(date +%Y%m%d)"
   ```
2. Wait for it to be Ready (`gh codespace list`)
3. Get the web URL: `gh codespace view --json url -c <name>`
4. Refresh AWS creds if needed (see AWS_INTEGRATION.md)
5. **Share the URL with the candidate via Teams chat**: `https://<codespace-name>.github.dev`

### During the interview

1. Candidate opens the URL in their browser — they see VS Code
2. Have them open a terminal and run the quick-check commands from README.md
3. They share their screen in Teams; you watch + ask questions
4. Walk through exercises in order (skip Ex 04/05 if running short)
5. Take notes against the rubric in `.interviewer/INTERVIEWER_GUIDE.md`

### Immediately after

1. Stop the codespace: `gh codespace stop -c <name>`
2. Delete it within 24h: `gh codespace delete -c <name>`
3. Score within 4h while it's fresh

## Time + cost estimate

| Activity | Time | Cost |
|---|---|---|
| One-time setup (this repo + AWS role + first codespace test) | 4 hours | ~$0 |
| Per interview (codespace spin-up + interview + cleanup) | 80 min | ~$0 (free tier) |
| **Total per candidate** | 80 min | ~$0 |

GitHub Codespaces free tier includes 60 core-hours per user per month. A 4-core codespace running for 75 min = 5 core-hours. That's 12 interviews per month free per interviewer account.

## What to send the recruiter

> "Tommy — for the technical round we'll use a GitHub Codespace (browser-based dev environment). 10 minutes before our session you'll get a URL via Teams chat. You'll need a GitHub account (free is fine) and Chrome/Edge/Firefox.
>
> No prep needed. We'll work through some Go, Kubernetes, AWS, and observability together. Show your thinking as you go.
>
> Confirm by Friday that you can:
> 1. Sign in to github.com
> 2. Open `https://github.com/codespaces` and see the page load
>
> Let me know if either step fails."

If he hits any issue with Codespaces, fallback to screen-sharing his local environment — lower signal but workable.
