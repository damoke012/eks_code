Addendum to the review above — I said I would confirm this rather than assume it.

`gha-risingwave-poc-secrets-role.tf` **is still present** in
`deploy/terraform/modules/irsa/`, alongside `gha-risingwave-pipeline-secrets-role.tf`,
`risingwave-2-role.tf` and `risingwave-onprem-role.tf`.

So the separation the deleted comment describes is not historical — it is live. After this
merge there would be **two** roles able to read `${cluster_name}/risingwave/*`: Tim's, which
is narrowly scoped, and this one, which trusts any `sub` in the repo. Rotating the prod
credential path would then have two consumers rather than one, and the wildcard-trusted role
is the one that is hardest to reason about.

That does not change the ask — narrow the subject, and keep `/risingwave/*` out of this role
or give it a role of its own. It does mean §2 is a live regression rather than a tidy-up.
