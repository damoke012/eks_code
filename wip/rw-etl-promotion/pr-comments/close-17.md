Closing this as superseded, not rejected.

#20 promotes `4873de43`, and `310aa151` is an ancestor of it:

    git merge-base --is-ancestor 310aa151 4873de43   ->  contained

So everything built here is already carried by #20's image. Verified by ancestry
rather than by PR date, because a newer PR is not necessarily a newer commit.

Worth noting for the next one: both PRs replaced the same digest
`sha256:d616242...`, so they were parallel rather than stacked. Merging this one
after #20 would have rolled QA back to a 26 August build, with both merges
reporting success.
