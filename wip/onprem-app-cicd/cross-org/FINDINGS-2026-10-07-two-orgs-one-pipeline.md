# The repo-location argument was the wrong argument

**2026-10-07.** From the call with Steve Duck, Timothy Preble, Idris Fagbemi, Pujit Koirala,
Dare Oke.

Scope: the RisingWave ETL pipeline repo and the on-prem app delivery path. The question
asked on the call was *which GitHub org the repo should live in*. That question does not
need an answer, and answering it is what has cost three weeks.

---

## What the call was actually about

Steve opened with the decision he thought was needed:

> *"The determination needs to be made where we want this to land. If we do need to shift
> it, Idris, how much effort is that? It sounds like it's more than just a copy and paste."*

Idris confirmed it is not a copy and paste — moving the repo means redirecting the pipeline
and everything pointing at the RisingWave server. Steve called it *"a little bit of a
restart."*

**Both are right about the cost and wrong about the need.** Nothing requires the repo to
move. What the platform needs from an app repo is one thing, and Doke said it plainly on
the call:

> *"The only thing we need from your repo is to be able to containerize and push the image
> to our artifactory, which is ECR."*

That is an **AWS** boundary, not a GitHub one. It does not care which org the source lives
in. The org debate is a consequence of one workaround — Idris suggesting Tim clone *our*
repo because we could not get a credential into *his* — and the workaround got mistaken for
the architecture.

## The constraint Tim stated, which we were not meeting

This is the finding. Tim described a standard, not a preference:

> *"We, as developers, have not been developing GitHub Actions, and we have not been custom
> curating our deployment from scratch. We have used actions that have come out of the
> variant space. And they've been curated and we just include them in. So like all this
> stuff right here could be an action. You just create it and then you publish it and then
> it gets used."*

And then, on credentials:

> *"You should actually be using actions instead of doing that. We've never done those repo
> keys and passing things around."*

**Our `app-template/.github/workflows/build-and-push.yml` is a 90-line workflow the app team
copies into their repo and thereafter owns.** It is exactly the "custom curating from
scratch" Tim says is not how USX works. He is not resisting the platform; he is telling us
the platform is shipped in the wrong shape.

He is also right about the keys. The template's promotion job writes a PR, which across an
org boundary needs a token stored in his org. That is the thing he says they have never
done, and it is also the thing that has been blocking us from the other side — **we have no
permission on his repo and he has none on ours.** Doke on the call:

> *"The problem with the key is because neither of us -- you, myself, Idris -- we don't have
> permission to your repo."*

Two teams, each unable to credential the other, is not solved by picking whose org wins. It
is solved by removing the credential.

## The design

Four files in `cross-org/`. Verified: all three workflows parse under `yaml.safe_load`.

```
app repo (Tim's org)                variant-inc                     AWS / on-prem
────────────────────                ───────────                     ─────────────
.github/workflows/deploy.yml
  44 lines, 2 values, NO SECRETS
  uses: variant-inc/usx-cicd-workflows
          /.github/workflows/
          app-build-push.yml@v1  ──► reusable workflow
                                       builds, assumes a role
                                       by OIDC, pushes ──────────►  ECR by digest
                                                                       │
                                     promote-from-ecr.yml ◄────────────┘
                                       sees a digest QA is not
                                       running, opens the PR HERE
                                       (overlays live here)
                                              │
                                              └──► Argo CD, QA then prod,
                                                   SAME digest, no rebuild
```

| Problem from the call | How this answers it |
|---|---|
| "Where should the repo live?" | Nowhere new. It stays in Tim's org. |
| "We use published actions, we don't curate pipelines" | The pipeline is a reusable workflow in the variant space. His file is 44 lines, 2 of which he sets. |
| "We've never done those repo keys" | There are none. OIDC issues a token per run that expires in minutes. |
| We have no access to his repo | We never need any. He adds 44 lines; we add a line to a trust policy. |
| He has no access to ours | He never needs any. The promotion PR is opened on our side. |
| Argo CD cannot read a private repo | It only ever reads ours. The orgs are joined by ECR, not by git. |

**Removing someone's access is deleting a line of Terraform.** No key to find, rotate or
revoke.

## ⚠️ Four things to verify before this is promised to anyone

Not yet measured. Each can invalidate part of the design.

1. **Can a repo in the USX org `uses:` a private reusable workflow in `variant-inc`?**
   GitHub allows it only when both orgs sit in the **same enterprise** *and* the source
   repo's Settings → Actions → General → Access permits it. If they are separate
   enterprises, this does not work at any permission level. **Fallback:** publish
   `usx-cicd-workflows` as a public repo — it contains workflow logic and no secrets, and
   the AWS trust policy is what grants anything. Decide this first; everything depends on it.
2. **Does the USX org permit `id-token: write`?** An org can disable OIDC for its repos.
   One line of org policy silently removes the entire credential model.
3. ~~**Exact org and repo names.**~~ **SETTLED 2026-10-07** by `gh api /user/orgs`: the two
   orgs are **`variant-inc`** and **`usxpressinc`**. The transcript's "Usxsqlopsprd" was a
   mis-transcription. The app repo name is still to confirm. The OIDC `sub` is an **exact
   string match**, so a guess does not fail loudly — it fails as a generic authorization
   error that reads like a permissions bug.
4. **Who adds the 44 lines to Tim's repo.** We cannot; we have no access. It is his change,
   and it should be a PR he reviews rather than something that appears.

## ✅ MEASURED 2026-10-07 — the design is viable, and the call's premise was wrong

```
gh api -X PUT /repos/variant-inc/usx-cicd-workflows/actions/permissions/access \
   -f access_level=enterprise
gh api /repos/variant-inc/usx-cicd-workflows/actions/permissions/access
  -> {"access_level": "enterprise"}
```

**It stuck.** `variant-inc` and `usxpressinc` are in the same GitHub enterprise, so a
repo in `usxpressinc` CAN call a **private** reusable workflow in `variant-inc`. Unknown 1
— the one everything depended on — is closed, and the public-repo fallback is not needed.

### ⚠️ "Neither of us have permission to your repo" is false

```
gh api /repos/usxpressinc/risingwave-poc --jq .permissions
  -> {"admin": false, "maintain": false, "pull": true, "push": true, "triage": true}
```

**`dare-x` has `push` on Tim's repo.** The credential gap that framed the whole call —
and that produced the clone-our-repo workaround, which produced the org debate — does not
exist in that direction. We could have opened the PR ourselves at any point.

Correct conduct is unchanged: it is Tim's repo, so the 44 lines go in as a **pull request
he reviews**, not a push. But "we are blocked on access" should not be said again without
running the command above first. A belief about permissions, repeated on a call by three
people, outranked a one-line check that contradicts it.

### ⚠️ The default branch is `master`, not `main`

`usxpressinc/risingwave-poc` defaults to **`master`**. The OIDC `sub` is a literal string
match, so a trust policy written for `main` fails with *"Not authorized to perform
sts:AssumeRoleWithWebIdentity"* — which reads as a permissions problem and sends you
looking at IAM. Templates corrected.

**Still open:** steps 3 and 4 (the `usxpressinc` Actions policy) need an org admin;
`dare-x` is not one. An `allowed_actions=selected` allowlist there would still block us,
and we have NOT measured whether one exists.

## Tim is blocked on something else entirely

> *"I'm having some problems locally with Docker... the folder is being owned by the user,
> the user is not included inside of the Docker container. So until I get that finished,
> like I'm way behind. So it's really a moot point to be talking about that."*

A container-user/file-ownership mismatch in his local build. **The org decision is not what
is stopping him today.** Worth an hour from someone who has hit it before; it is a common
and well-understood problem, and he is spending days on it alone while the meeting discusses
repository placement.

---

## Proven / killed / traps

- **Proven:** the three workflows parse. The ECR-digest promotion path itself was proven end
  to end on op-usxpress-qa on 2026-08-20 — though carrying a smoke payload, not the real
  pipeline.
- **Killed:** moving the repo between orgs. It costs a partial restart, by Idris's
  assessment, and buys nothing the OIDC trust policy does not give free.
- **Killed:** the copy-the-template model in `app-template/`. It is the right content in the
  wrong packaging, and the call told us so explicitly. Keep it as the reference
  implementation; stop shipping it as the interface.
- **Killed:** a cross-org PAT or deploy key for the promotion PR. Not needed once the
  promotion runs on the side that owns the overlays.
- **Trap:** the OIDC `sub` is org-qualified. An app repo that is later **transferred between
  orgs** stops authenticating immediately, with nothing changed on its side and an error that
  names permissions rather than the claim. If the org question is ever revisited, the trust
  policy moves in the same change or the pipeline breaks.
- **Trap:** pinning `environment:<name>` in the `sub` requires the calling job to declare
  `environment:`. Our policy pins repo + ref for exactly this reason. See
  `gha-oidc-needs-environment-claim`.
- **Trap:** a scheduled promotion workflow that finds nothing still reports success. Green
  here means "the poll ran", not "an image was promoted". Read the digest line.
