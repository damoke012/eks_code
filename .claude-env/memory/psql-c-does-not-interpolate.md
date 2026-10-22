---
name: psql-c-does-not-interpolate
description: "psql -c never substitutes :'var' — only file/stdin input does; and a \\c <db> inside an applied .sql silently overrides the configured database"
metadata:
  node_type: memory
  type: reference
---

Two psql behaviours that each cost a round trip on 2026-10-09 while enabling CDC on op-dev.

## `-c` does not interpolate variables

    psql -v ep="$P" -c "CREATE ROLE x WITH LOGIN PASSWORD :'ep';"
    # ERROR:  syntax error at or near ":"

`-v` sets the variable, but **substitution happens only for input read from a file or
stdin**. A `-c` string is sent as-is, so `:'ep'` reaches the server literally. Worse, the
next statements ran and failed with `role "x" does not exist`, which reads as a different
problem than the one that occurred.

**Pipe it instead** — this interpolates AND keeps the credential out of `argv`, where `ps`
and shell history can see it:

    printf "CREATE ROLE x WITH LOGIN REPLICATION PASSWORD '%s';\n" "$P" \
      | psql -h "$H" -U postgres -d postgres -v ON_ERROR_STOP=1 -q

## A `\c <db>` inside the file beats the connection you configured

`pipelines/300-Employee/001-create_rdms_tables.sql:21` is a literal `\c entities`. Our
`apply.sh` connects to `$POSTGRES_ENTITY_DB` and the file then reconnects to a hardcoded
name, so **the variable is decorative for that file**. Setting it to `rw_entity` produced

    psql: error: \connect: ... FATAL:  database "entities" does not exist

which reads as a configuration error and is really a hardcoded name. Grep an applied tree
for `\c ` and `\connect` before choosing any database name:

    grep -rnE '\\connect|\\c [a-z]|SET search_path' pipelines/

## And the one that makes a landed change look absent

`ALTER SYSTEM` writes `postgresql.auto.conf` but **`pg_settings.pending_restart` stays
`false` until the config is re-read**. Run `select pg_reload_conf();` first, then read
`pending_restart`. Without it the setting looks like it never applied. `ALTER SYSTEM` does
survive a pod restart, because `auto.conf` lives on the data volume.

Related: [[prose-through-shell-strings]], [[validator-checks-every-value-not-the-selected-ones]].
