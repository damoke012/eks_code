Idris — good work on #19, that was a fast turnaround and it holds up. I checked each item against the live accounts rather than reading the summary, and everything came back clean: the prod account is right, the unknown-environment arms exit rather than defaulting, the guardrail regex genuinely ran under `-P`, and `[ -z "${!var:-}" ]` catches empty as well as unset so the blank overlay values will refuse properly. The QA and prod ExternalSecret indices line up too — your two summary lines contradicted each other on that one, but the code was right; it was only the write-up that was off.

Worth knowing: #19 also removes the `secrets.AWS_ACCOUNT_ID` usage that #18 introduces, so the two are no longer pulling against each other.

**One change and I'll approve.**

The `${ENV}` substitution on the secret paths sends QA to `op-usxpress-qa/risingwave-2/postgres`, and that does not exist. I should have told you this earlier and it was not in the ticket: **`risingwave-2` is dev-only.** It is our own platform work, not a second environment tier, and it is never promoted. QA and prod have `risingwave` and nothing else. I confirmed it this morning — dev has both, QA has only `risingwave`, prod has neither yet because its Terraform has not run.

So the namespace needs the same treatment you already gave the account ID — mapped, not interpolated:

    case "${ENV}" in
      dev)  AWS_ACCOUNT_ID="700736442855"; RW_NS="risingwave-2" ;;
      qa)   AWS_ACCOUNT_ID="527101283767"; RW_NS="risingwave" ;;
      prod) AWS_ACCOUNT_ID="937464026810"; RW_NS="risingwave" ;;
      *)    echo "::error::Unknown environment '${ENV}'"; exit 1 ;;
    esac

then `--secret-id "op-usxpress-${ENV}/${RW_NS}/postgres"`.

Dev is unchanged by that, so it needs no sign-off from anyone. And it means the `risingwave-2` → `risingwave` rename you deferred is now required for QA rather than optional — you were right to pull it out of this PR, it just turns out QA cannot work without it.

The break is latent rather than live, since that workflow only runs with `ENV=dev` today. But the point of the change is to make it work for the other environments, so it will bite the first time QA runs it.

**Two smaller things:**

- Test-plan item 4 — `.sql` refused when `POSTGRES_SERVER` is empty. I would rather see that run than reasoned about. The whole value of that guard is in the failure path.
- **#18** is 112 files and sixty thousand lines under a title about one ARN. The workflow part of it is now redundant, since #19 fixes that. Could the PowerShell tooling and docs go into their own PR, or the whole thing be closed? As it stands nobody can review it properly, and that is a shame because the ARN fix in it was correct.

**And one on me:** the prod account ID in INFRA-1675 was wrong — I wrote `786352483360`, which is the **playground** account. You caught it and used `937464026810`. I have corrected the ticket. Worth flagging because if that number is in anything else of mine, it needs the same fix.
