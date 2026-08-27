# base/job.yaml — the one change needed

The Job currently names three credentials explicitly:

```yaml
          env:
            - name: RW_PASSWORD
              valueFrom:
                secretKeyRef: { name: etl-pipeline-credentials, key: RW_PASSWORD }
            - name: PG_PASSWORD
              valueFrom:
                secretKeyRef: { name: etl-pipeline-credentials, key: PG_PASSWORD }
            - name: PG_USER
              valueFrom:
                secretKeyRef: { name: etl-pipeline-credentials, key: PG_USER }
```

The secret now carries **twelve** keys. Enumerating them here would mean this list and the
ExternalSecret must be kept in step by hand — a second positional-style coupling, in a
second file. Replace the whole `env:` block with one line added to `envFrom:`:

```yaml
          envFrom:
            - configMapRef:
                name: etl-pipeline-endpoints    # per-cluster coordinates and choices
            - secretRef:
                name: etl-pipeline-credentials  # every credential, whatever the set is
```

Then adding a connector means editing the ExternalSecret only.

⚠️ `secretKeyRef` and `secretRef` both resolve **at pod creation**. The Job is created fresh
on every sync, so it always reads current values — but a *long-running* container started
before a rotation keeps serving the old one until it restarts. That has bitten us before
and it is why this is a Job rather than a Deployment.
