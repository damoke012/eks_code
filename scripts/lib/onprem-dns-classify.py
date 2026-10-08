#!/usr/bin/env python3
"""Classify one on-prem cluster's hostname claims.

Reads `kubectl get virtualservices,gateways -A -o json` on stdin and prints, for every
non-wildcard usxpress.io host the cluster declares:

  RECORD  does Route 53 already hold an A/CNAME for it (from the zone dump, NOT from DNS)
  TARGET  do the external-dns target IPs belong to THIS cluster's nodes
  DECL    which VirtualService/Gateway declares it

Then flags the five ways a hostname silently fails to work.

Route 53 is the instrument for "does the record exist" on purpose: the usxpress.io SOA
minimum is 86400, so resolving a name that has no record yet pins a negative answer for
24 hours. Names confirmed present are written to --safe-list for the caller to resolve;
absent names are never queried.

env: ENV (dev|qa|prod), NODES (newline-separated node IPs)
argv: --rrset <route53 json|->   --safe-list <path>
"""
import json
import os
import sys

env = os.environ["ENV"]
nodes = set(os.environ["NODES"].split())

args = sys.argv[1:]
rrset_path = args[args.index("--rrset") + 1] if "--rrset" in args else "-"
safe_path = args[args.index("--safe-list") + 1] if "--safe-list" in args else None

existing = set()
measured = rrset_path != "-" and os.path.exists(rrset_path) and os.path.getsize(rrset_path) > 0
if measured:
    for r in json.load(open(rrset_path))["ResourceRecordSets"]:
        if r["Type"] in ("A", "CNAME"):
            existing.add(r["Name"].rstrip(".").lower().replace("\\052", "*"))

claims = {}
for item in json.load(sys.stdin).get("items", []):
    meta = item["metadata"]
    ann = meta.get("annotations") or {}
    spec = item.get("spec", {})

    hosts = list(spec.get("hosts") or [])
    for srv in spec.get("servers", []):
        hosts += srv.get("hosts") or []
    if ann.get("external-dns.alpha.kubernetes.io/hostname"):
        hosts += ann["external-dns.alpha.kubernetes.io/hostname"].split(",")

    target = ann.get("external-dns.alpha.kubernetes.io/target") or ""
    tips = {t.strip() for t in target.split(",") if t.strip()}

    for h in hosts:
        h = h.strip().lower().rstrip(".")
        if "*" in h or not h.endswith("usxpress.io"):
            continue
        claims.setdefault(h, []).append(
            (meta.get("namespace", "-"), meta["name"], item["kind"], tips)
        )

hdr_host, hdr_rec, hdr_tgt = "HOST", "RECORD", "TARGET"
print()
print("  %-44s %-8s %-9s %s" % (hdr_host, hdr_rec, hdr_tgt, "DECLARED BY"))

gaps = []
for h in sorted(claims):
    owners = claims[h]
    rec = "present" if h in existing else ("ABSENT" if measured else "UNKNOWN")

    tips = set().union(*[o[3] for o in owners])
    if not tips:
        tgt = "none"
    elif tips <= nodes:
        tgt = "ok %d" % len(tips)
    else:
        tgt = "FOREIGN"

    decl = ", ".join("%s/%s" % (o[0], o[1]) for o in owners)
    print("  %-44s %-8s %-9s %s" % (h, rec, tgt, decl))

    parts = h.split(".")
    envtag = parts[-3] if len(parts) >= 3 else ""
    if envtag.startswith("op-") and envtag != "op-" + env:
        gaps.append(
            "%s is declared on op-%s but names %s — external-dns SILENTLY skips a record "
            "another txt-owner-id holds. No error, no event, no working hostname."
            % (h, env, envtag)
        )
    if tgt == "FOREIGN":
        gaps.append(
            "%s targets %s, which are not nodes of op-%s — a copied VirtualService"
            % (h, sorted(tips - nodes), env)
        )
    if not tips:
        gaps.append(
            "%s has no external-dns target annotation — no record will be created" % h
        )
    if rec == "ABSENT":
        gaps.append(
            "%s is routed in Istio but has NO A/CNAME in Route 53. Do NOT resolve it to "
            "confirm — the 86400s negative TTL would hide it for a day. Fix the "
            "annotation, then resolve once." % h
        )
    if len(owners) > 1:
        gaps.append("%s is declared %d times (%s) — duplicate claim" % (h, len(owners), decl))

for i, g in enumerate(gaps, 1):
    print("  ** GAP %d: %s" % (i, g))
if not gaps:
    print("  no gaps in the cluster half for op-%s." % env)

if safe_path and measured:
    safe = [h for h in sorted(claims) if h in existing]
    with open(safe_path, "a") as fh:
        fh.write("".join(h + "\n" for h in safe))
    print("\n  %d name(s) confirmed in Route 53 — safe to resolve" % len(safe))
elif safe_path:
    print("\n  Route 53 NOT MEASURED — nothing will be resolved. By design, not by failure.")
