# The RisingWave pipeline artefact: the SQL and the tooling that applies it, as one
# immutable image. Both travel together so a prod run cannot differ from the QA run by a
# client version or a missing package.
#
# Nothing environment-specific is baked in. Hosts, ports and credentials are resolved at
# run time from the cluster the Job lands on.
FROM alpine:3.20

RUN apk add --no-cache postgresql16-client bash ca-certificates \
 && adduser -D -u 10001 applier

WORKDIR /pipeline
COPY --chown=applier:applier pipelines/ /pipeline/pipelines/
COPY --chown=applier:applier smoke/     /pipeline/smoke/
COPY --chown=applier:applier build/apply.sh /pipeline/apply.sh
RUN chmod 0755 /pipeline/apply.sh

USER 10001
ENTRYPOINT ["/pipeline/apply.sh"]
