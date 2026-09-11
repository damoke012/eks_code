#!/usr/bin/env python3
"""Render pipelines/shared/000-secrets.rw for one environment, Kafka only.

  render-kafka-secrets.py <template.rw> <secret.json> <env> <out.rw>

Substitutes the %TOKEN% placeholders with values from the environment's
op-usxpress-<env>/risingwave/kafka record, drops every MongoDB statement, and
REFUSES to write a file that would create a broken secret. No value is printed.

The two refusals are the point. The GHA workflow this mirrors has neither, which
is why an empty schema-registry field would have produced twelve green secrets
holding ''. See wip/rw-etl-promotion/STATE.md, 2026-09-11.
"""
import json, re, sys

def die(msg):
    sys.stderr.write("refusing: %s\n" % msg)
    sys.exit(1)

if len(sys.argv) != 5:
    die("usage: render-kafka-secrets.py <template.rw> <secret.json> <env> <out.rw>")
tpl_path, sec_path, env, out_path = sys.argv[1:]

tpl = open(tpl_path, encoding="utf-8").read()
sec = json.load(open(sec_path, encoding="utf-8"))

# Key casing differs by environment: dev is KAFKA__, on-prem QA is kafka__.
# Find the prefix from a key we know exists rather than assuming either.
prefix = None
for k in sec:
    if k.endswith("bootstrap_server"):
        prefix = k[: -len("bootstrap_server")]
        break
if prefix is None:
    die("no *bootstrap_server key in the secret record -- wrong record, or empty")

def val(suffix):
    v = sec.get(prefix + suffix)
    if v is None:
        die("the secret record has no %s%s" % (prefix, suffix))
    if not str(v).strip():
        die("%s%s is empty -- fix the record before creating secrets from it" % (prefix, suffix))
    return str(v)

# group_id_prefix is derived, not stored -- matching secret.yaml exactly,
# including prod's missing underscore.
gid = "prodkafka_prefix" if env == "prod" else "%s_kafka_prefix" % env

mapping = {
    "%KAFKA_BOOTSTRAP_SERVER%":          val("bootstrap_server"),
    "%KAFKA_API_KEY%":                   val("api_key"),
    "%KAFKA_API_SECRET%":                val("api_secret"),
    "%KAFKA_SERVICE_ACCOUNT%":           val("service_account"),
    "%KAFKA_RESOURCE_ID%":               val("resource_id"),
    "%KAFKA_REST_ENDPOINT%":             val("rest_endpoint"),
    "%KAFKA_SCHEMA_REGISTRY_ENDPOINT%":  val("schema_registry_endpoint"),
    "%KAFKA_SCHEMA_REGISTRY_API_KEY%":   val("schema_registry_api_key"),
    "%KAFKA_SCHEMA_REGISTRY_API_SECRET%": val("schema_registry_api_secret"),
    "%KAFKA_GROUP_ID_PREFIX%":           gid,
}

# Kafka only. A MongoDB record does not exist on QA, and secret.yaml's `both`
# default would substitute nothing and create three secrets holding ''.
kept = [ln for ln in tpl.splitlines() if "mongodb" not in ln.lower()]
body = "\n".join(kept) + "\n"

for token, value in mapping.items():
    body = body.replace(token, value)          # literal, not regex

# ---- the gates -----------------------------------------------------------
left = sorted(set(re.findall(r"%[A-Z_]+%", body)))
if left:
    die("unsubstituted placeholders would become literal secret values: %s" % ", ".join(left))

if re.search(r"AS\s*''", body):
    die("a CREATE SECRET would store an empty string")

names = re.findall(r"CREATE\s+SECRET\s+(\w+)", body, re.I)
kafka = [n for n in names if n.startswith("kafka_")]
if len(kafka) != 12:
    die("expected 12 kafka_* CREATE SECRET statements, found %d: %s" % (len(kafka), kafka))
if len(names) != len(kafka):
    die("non-kafka CREATE SECRET survived the filter: %s" % [n for n in names if n not in kafka])

open(out_path, "w", encoding="utf-8").write(body)
sys.stderr.write("rendered %d kafka secrets for %s, no placeholders left, no empty values\n"
                 % (len(kafka), env))
for n in kafka:
    sys.stderr.write("  %s\n" % n)          # names only
