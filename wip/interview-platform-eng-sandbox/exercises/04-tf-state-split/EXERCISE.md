# Exercise 04 — Sketch a Terraform state split

**Time:** ~10 minutes (design conversation, no code change required)

## Scenario

You inherit a single Terraform state file with **~8,000 resources** in it. Plans take 18 minutes. Last week, an engineer accidentally destroyed the wrong subnet because the blast-radius preview was too noisy to read. The team is now afraid to touch it.

Open [`monolith.tf`](monolith.tf) — that's a heavily abbreviated representation of what's there (VPC, EKS, RDS, IAM, apps, secrets, all in one).

## Your task

Sketch your migration plan **on the whiteboard / in a doc**. Don't write Terraform. Walk us through:

1. **The target topology** — how many root modules / states would you end up with, and where do you draw the boundaries? Why those boundaries?
2. **The migration steps** — given a live, in-use state file, how do you move resources between states without `apply`ing the world?
3. **The coordination problem** — how do you stop people from racing each other during the migration?
4. **The rollback plan** — what if a `state mv` goes wrong?

## What we're looking for

- You think clearly about WHERE to draw boundaries and WHY — and the answer survives the next team reorg
- You're specific about HOW the migration happens without breaking the live state
- You think about the humans, not just the tooling — what stops people racing each other during the move?
- You think through what happens if something goes wrong partway through
- You're honest about the scale of your prior experience and what you'd want to add for this size

## Bonus

- How does your answer change if the team is 5 engineers vs 50?
- How does it change if 50% of the resources have lifecycle hooks / are stateful (RDS, EKS) vs purely declarative (IAM, S3)?
