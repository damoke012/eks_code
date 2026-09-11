#!/usr/bin/env python3
"""Add a consumer_groups block to a user file in variant-inc/ix-kafka-topics-users.

    python3 scripts/add-consumer-group.py <users/NAME.yml> <group-prefix> <project>

Inserts the block ABOVE `topics:`, which is where every other user file carries it.
Refuses if one already exists, or if the file is not the shape we expect.

⚠️ The ACL that results is `dx__${local.prefix}${prefix}` (deploy/terraform/users.tf:44) --
`dx__qa_<prefix>` on QA, `dx__<prefix>` on prod, since prod's confluent_prefix is empty.
The consumer MUST join a group with that exact prefix. For RisingWave that means
secret.yaml's kafka_group_id_prefix derivation has to change too, or this grant matches
nothing and the deploy still goes green. See wip/rw-etl-promotion/STATE.md 2026-09-11.
"""

import sys
path, prefix, project = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines()
if any(l.startswith("consumer_groups:") for l in lines):
    sys.exit(f"refusing: {path} already has a consumer_groups block")
if not any(l.startswith("topics:") for l in lines):
    sys.exit(f"refusing: {path} has no top-level topics: block — unexpected shape")
block = ["consumer_groups:", f"  - prefix: {prefix}", "    used_by:",
         f"      project: {project}", "      deployed_in: others"]
at = next(i for i, l in enumerate(lines) if l.startswith("topics:"))
out = lines[:at] + block + lines[at:]
open(path, "w").write("\n".join(out) + "\n")
print(f"inserted {len(block)} lines before topics: in {path}")
