Requesting changes — detail in the two comments above.

Short version: the subject wildcard `repo:variant-inc/risingwave-pipeline:*` also matches
`repo:…:pull_request`, and the same commit adds Tim's production secret path
`${cluster_name}/risingwave/*` to that role. Together that is a wildcard-trusted role able
to read production RisingWave credentials, and `gha-risingwave-poc-secrets-role.tf` still
exists, so the separation is being removed rather than tidied.

To unblock: name the subjects explicitly (`StringLike` takes a list — `master` plus the
three `environment:` values), and keep `/risingwave/*` out of this role or give it its own.

The diagnosis and the `var.cluster_name` parameterisation are both right, and I will approve
the same day those two land.
