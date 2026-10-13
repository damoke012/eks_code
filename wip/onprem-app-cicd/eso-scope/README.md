# Scope the on-prem ESO role from `*` to the paths actually read

Measured 2026-10-13 on op-usxpress-dev.

`op-usxpress-dev-external-secrets` carries one inline policy, `secrets-manager`,
granting GetSecretValue / DescribeSecret / ListSecrets on `Resource: "*"`. There are
149 secrets in account 700736442855, so every ExternalSecret on the cluster can read
all of them -- `op-usxpress-dev/talosconfig` and `op-usxpress-dev/octopus-worker`
among them. Read only; no write or delete.

The ClusterSecretStore reports `ReadWrite` capabilities. That is ESO's feature label,
not the permission. IAM allows reads only.

## Why the obvious fix would have broken three namespaces

Scoping to `op-usxpress-dev/*` looks right and is wrong. Enumerating every
ExternalSecret on the cluster found 30 paths across 13 namespaces, FIVE of them
outside that prefix:

    enterprise    azure-app-dx-dev-usxpress-brands-api
    geoservices   geoenrichment-sync-handler-m-u
    io-curt       dx--ccloud-kafka-master
    io-curt       dx--ccloud-schema-registry-master
    io-curt       dx__opsconsumer-kafka-creds

policy-op-usxpress-dev-external-secrets.json grants the prefix plus those five by
name. ListSecrets stays account-wide: it returns names only, and ESO uses it to
resolve.

## Before applying

Re-run the enumeration. This list is a snapshot, and a new ExternalSecret added since
would be denied with no warning until its pod could not start.

    kubectl get externalsecrets.external-secrets.io -A -o json | jq -r '.items[]
      | .metadata.namespace as $n
      | ((.spec.data[]?.remoteRef.key), (.spec.dataFrom[]?.extract.key))
      | "\($n)  \(.)"' | sort -u

## After applying

A denied read does not fail loudly. ExternalSecret goes SecretSyncedError, the Secret
keeps its last good value, and the pod that consumes it only notices at next creation.
Check every ExternalSecret's status, not a sample.

## QA and prod

NOT MEASURED. The same `Resource: "*"` is likely present on both; run the same two
commands against op-usxpress-qa and op-usxpress-prod before assuming either way.

## Proven / tested and killed / traps

PROVEN  op-usxpress-dev-external-secrets grants read on every secret in 700736442855
        (2026-10-13). 30 paths are actually read, 5 outside the cluster prefix.
KILLED  "scope it to op-usxpress-dev/*" -- would deny three namespaces.
        "the store says ReadWrite so it can write" -- IAM says otherwise.
TRAPS   `list-secrets --max-results 100` paginates; `length(SecretList)` printed a
        count PER PAGE (10x14 + 9 = 149). The first listing silently omitted a secret
        created an hour earlier and would have read as "it does not exist".
