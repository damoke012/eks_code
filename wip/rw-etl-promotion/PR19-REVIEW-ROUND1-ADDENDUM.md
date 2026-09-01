Correction to my own review, immediately above.

I left "which namespace should QA and prod read from?" as an open question for you. It is not open, and I should not have asked it.

**`risingwave-2` is dev-only.** It is our own platform work; it is not a second tier and it is never promoted. QA and prod have `risingwave` and nothing else. That is settled, and it needs no sign-off from Tim.

So the mapping in the blocker above is the change to make, exactly as written:

```bash
case "${ENV}" in
  dev)  AWS_ACCOUNT_ID="700736442855"; RW_NS="risingwave-2" ;;
  qa)   AWS_ACCOUNT_ID="527101283767"; RW_NS="risingwave" ;;
  prod) AWS_ACCOUNT_ID="937464026810"; RW_NS="risingwave" ;;
  *)    echo "::error::Unknown environment '${ENV}'"; exit 1 ;;
esac
```

With that in, the blocker clears and I am happy for this to merge. The only outstanding item is test-plan #4 — `.sql` refused when `POSTGRES_SERVER` is empty — which I would like run rather than reasoned about.
