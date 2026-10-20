# AWS Terraform provider 6.69.1 blocks any deploy that reads a Lambda function

**Date raised:** Thursday of the week ending 2026-10-17, reported at the Platform Delivery
and Reliability Review on **2026-10-20**.
**Reported by:** Parul (fix), Rohit (status).
**Hit:** `ix-kafka-topics-users`, **dev** deployment, through Octopus.
**Status:** worked around on every environment by one merge. **Not fixed.** A patch release
of the provider now exists and has not yet been tested.
**Doke asked for this to be documented and ticketed** — *"anything that impacts Kafka is
something we should document"* — because the same failure will appear elsewhere.

## What happened

An Octopus deployment of the Kafka topics/users project failed. The failing step was a
Terraform **read**, not an apply: nothing had been changed when it stopped.

The newest `hashicorp/aws` provider had been released **that same day**. The repository does
not pin the provider, so the run took the new one. Reading the existing
`aws_lambda_function` resource made the provider issue an **`ListVersionsByFunction`** call
to the AWS API, and that call errored.

Parul, verbatim: *"in our code we have just written `resource aws_lambda_function`, but what
happens in the background is, in the provider, using AWS APIs it tries to call this
`ListVersionsByFunction` call, which was failing. So nothing from our end — it's not there
in our code."*

Why these functions have many versions to walk: **Octopus publishes a new version of the
Lambda function on every deploy.** The function accumulates versions, and the provider's read
path enumerates them.

## The fix that is in place

A **provider version constraint below 6.69.1** — `< 6.69.1` — merged into the Terraform
repository. Because the constraint lives in the shared configuration, it reached **all
environments at once**; there is no per-environment work outstanding.

Parul also changed the Lambda module's publish behaviour (reported on the call as *"this
publish faults"*, most likely `publish = false`). ⚠️ **NOT VERIFIED** — read the merged diff
before repeating this as fact.

### What this does and does not block

| | Blocked? |
|---|---|
| Newer **Lambda** function versions / runtimes | **No.** These still work. |
| Newer **AWS provider** versions | **Yes**, anything from 6.69.1 up, until the pin is lifted. |

The two get conflated in conversation. The upgrade that is frozen is the **provider's**.

## Exit criteria

1. A patch release of the AWS provider above 6.69.1 is published (one already exists as of
   2026-10-20 and is untested here).
2. `terraform plan` against the Kafka project reads `aws_lambda_function` successfully on
   that version.
3. The constraint and the publish change are reverted together, in one PR, and the Kafka
   **dev** deploy is green before anything else moves.

Parul owns the re-test and said she will attach the upstream AWS/provider issue to the
documentation.

## If you see it again

The symptom is a **plan or refresh failure naming `ListVersionsByFunction`**, in a project
that contains a Lambda function, immediately after the provider was picked up fresh.

1. Read the **raw** Octopus log and search for `ListVersionsByFunction`. The rendered log
   view truncates it; Parul had to open the raw log to show the error.
2. Check which provider version the run resolved. A repository that gitignores
   `.terraform.lock.hcl` resolves it at init time, so two runs an hour apart can differ.
3. Grepping our own Terraform for the failing API **finds nothing**, and that is expected —
   the call is inside the provider. Do not read the empty grep as "not us".
4. Pin below 6.69.1 and re-run. Pin in the shared configuration so one change covers every
   environment.

## Open items

| # | Item | Owner |
|---|---|---|
| 1 | Jira ticket documenting this (placeholder acceptable) | Parul / Idris to file |
| 2 | Add it to the SOP so the next person recognises it | Parul |
| 3 | Attach the upstream provider issue number | Parul |
| 4 | Re-test the patch provider release, then revert the pin | Parul |
| 5 | Reconcile `iac-tf-manual-runs/apps/common/gha_ecr_push_roles` — it declares `aws = "~> 6.69"`, i.e. `>= 6.69, < 7.0`, which **admits the blocked range** | Doke |

## Proven

* The AWS provider released on the day of the incident fails at **read** of
  `aws_lambda_function` by way of an internal `ListVersionsByFunction` call.
* Constraining the provider below 6.69.1 unblocks the deployment.
* The constraint is shared, so one merge covered every environment — confirmed by Parul on
  the call.
* Octopus publishes a new Lambda version on every deploy, so the version list these
  functions carry is long and grows with each release.
* Nothing in USX Terraform calls that API directly.

## Not captured

* **The error text itself.** It was shown on a shared screen from a raw Octopus log and is
  not in the transcript. Get it from the failed task's raw log and paste it into the ticket —
  the message is the only thing that makes this findable by the next person.
* The exact provider version the run resolved to, and the exact constraint syntax merged.
* The upstream issue reference.

## Traps

* **The failure is at read, so nothing was applied and no resource looks wrong.** It reads
  like a credentials or permissions problem.
* **Our code is innocent and that is misleading.** The resource block is three lines; the
  failing behaviour is the provider's.
* **An unpinned provider is an ungated change.** Any repository that gitignores the lock file
  takes whatever was published that morning. Release day is the exposure.
* **Pinning is not fixing.** The pin has no expiry and no alert. Item 4 above is the only
  thing that stops `< 6.69.1` being load-bearing a year from now.
