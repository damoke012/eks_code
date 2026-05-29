# pipeline.yaml changes (variant-inc/risingwave-pipeline, branch feat/onprem-rw2-adaptation)

These changes route the **execute** job onto the in-cluster self-hosted ARC
runner (so it can reach `risingwave-frontend.risingwave-2.svc:4567`) and make
sure the runner has the CLI tools the job needs.

The **validate** and **approve** jobs stay on `ubuntu-latest` (GitHub-hosted) —
they only need git/grep and an approval gate, no cluster access.

## Change 1 — execute job `runs-on`

Find the `execute:` job (around line 154) and change:

```yaml
  execute:
    needs: [validate, approve]
    runs-on: ubuntu-latest        # <-- OLD
```

to:

```yaml
  execute:
    needs: [validate, approve]
    runs-on: risingwave-pipeline  # <-- self-hosted ARC runner scale set
```

The label `risingwave-pipeline` matches `runnerScaleSetName` in the
gha-runner-scale-set HelmRelease.

## Change 2 — install tooling on the runner

The default ARC runner image (ghcr.io/actions/actions-runner) is minimal: it
has git + sudo + apt, but NOT `aws` CLI or `jq`. The execute job already
installs `postgresql-client`; add aws CLI + jq.

Add this step in the `execute` job, BEFORE the "Configure AWS via OIDC" step:

```yaml
      - name: Install tooling (self-hosted runner)
        shell: bash
        run: |
          set -e
          sudo apt-get update -qq
          sudo apt-get install -y -qq jq unzip curl
          if ! command -v aws >/dev/null 2>&1; then
            curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
            unzip -q /tmp/awscliv2.zip -d /tmp
            sudo /tmp/aws/install --update
          fi
          aws --version
          jq --version
```

The existing "Install PostgreSQL client" step (`postgresql-client-16`) can stay
as-is — it works the same on the self-hosted runner.

## Why not bake a custom runner image?

For v1 we install tools per-run (adds ~30-40s). It avoids standing up a custom
image build + ECR push pipeline. FOLLOWUP: bake a custom runner image
(psql + aws + jq preinstalled) in ECR (064859874041) and point the scale set
`template.spec.containers[0].image` at it to cut per-run install time.

## Note on AWS reachability from the runner

The execute job assumes `gha-op-usxpress-dev-risingwave-pipeline-secrets` via
GitHub OIDC. The runner pod needs egress to:
  - GitHub (token + job orchestration) — already required for the runner to function
  - AWS STS + Secrets Manager (us-east-2) — cluster has internet egress
  - risingwave-frontend.risingwave-2.svc:4567 (in-cluster) — cross-namespace ClusterIP

No NodePort / external ingress needed — that's the whole point of running
in-cluster.
