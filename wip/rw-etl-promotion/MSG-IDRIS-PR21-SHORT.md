Idris — left detailed comments on PR #21. Short version:

Not approving it yet, and it is only because of the two overlay lines.

PIPELINE_DIR moves from /pipeline/smoke to /pipeline/pipelines on QA and prod.
That is the go-live. It is the thing we have been working toward, and I am not
approving it inside a PR about hardening a script, and not on both environments
at once.

Please:

1. Split the two overlay files into their own PR. QA only, "cutover" in the
   title. I will review that one properly and prod follows once QA has run.
2. In that PR, list every directory under pipelines/ and mark each one in or
   out with a reason. Three we agreed on 26 Aug are not in the exclude list -
   900-user-access, 001-secrets-mongodb, 400-sink.
3. Two fixes in apply.sh: hash the rendered SQL rather than the template
   (otherwise changing a variable value gets skipped and the Job still goes
   green), and fail instead of exit 0 when EXCLUDE_RE matches everything.
4. Write down what we do after a bad apply. There is no way back today.

The rest of the PR is good - the validation before any DB connection is exactly
right, and EXCLUDE_RE with the stable root is the better design. Happy to merge
that half as soon as it is on its own.

Ping me when the QA PR is up and I will turn it round same day.
