Tim - correct, on-prem does not follow that pattern. Here is the mapping.

Your DX flow moves a BRANCH between environments. On-prem moves an IMAGE DIGEST. That is
the one difference everything else follows from.

DX today:
  push a branch       -> auto-deploys to dev
  Octopus             -> deploy that branch to QA
  PR into main        -> merge deploys to production

On-prem:
  push a branch       -> nothing deploys. CI validates the SQL, that is all.
  merge to master     -> builds the applier image, pushes to ECR by digest
  promotion PR, dev   -> bumps that digest in deploy/.../dev, Argo CD syncs dev
  promotion PR, QA    -> same digest, no rebuild, Argo CD syncs QA
  promotion PR, prod  -> same digest again

So there is no Octopus in this path and no deploy button. The deploy IS the merge of a
small PR that changes one line - the digest. Argo CD watches git and applies what it sees.

Three practical consequences for you:

1. Your branch is never deployed anywhere. Open a PR into master, and once it is merged
   the image is built. Nothing reaches a cluster from a branch.

2. The same artifact goes to all three environments. Nothing is rebuilt per environment, so
   QA and prod run the bytes dev ran. What differs per environment is config only - topic,
   consumer group, schema - and that is a ConfigMap edit with no rebuild.

3. Production is still a PR you merge, which is the part that matches your flow. It is just
   a promotion PR carrying a digest rather than your code.

Where we actually are today, so you are not surprised:

QA is wired and deployed successfully last night. Dev is being wired right now - that is
why a push does not reach dev yet, and it is the gap I am closing. Prod has the directory
but no promotion workflow yet.

The dev and QA promotion PRs are opened and merged automatically, because one sat open for
eight days in September and nothing deployed. Prod should stay a human merge.

One warning about a different repo. RisingWave itself - the database, not your SQL - lives
in iaac-risingwave-onprem, and every cluster follows main there on a five minute interval.
A merge to that repo reaches production in about five minutes with no approval. That is not
your pipeline, but if you ever touch that repo, know that merging is deploying to prod.
