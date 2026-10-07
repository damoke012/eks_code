# The SQL applier TOOLING, with no SQL in it.
#
# Published once to ECR as risingwave/sql-applier:<version>. An app repo that owns
# only SQL builds a three-line image FROM this and adds its own pipelines/ — so the
# app repo needs no Dockerfile, no apply.sh, and no knowledge of how applying works.
#
# Updating apply.sh for every consumer is then one build here, not a PR per repo.
FROM alpine:3.20

RUN apk add --no-cache postgresql16-client bash ca-certificates \
 && adduser -D -u 10001 applier

WORKDIR /pipeline
COPY --chown=applier:applier apply.sh /pipeline/apply.sh
RUN chmod 0755 /pipeline/apply.sh

# Consumers COPY their SQL to /pipeline/pipelines/. An image built FROM this with no
# SQL added applies nothing, which is a no-op rather than a failure.
RUN mkdir -p /pipeline/pipelines && chown applier:applier /pipeline/pipelines

USER 10001
ENTRYPOINT ["/pipeline/apply.sh"]
