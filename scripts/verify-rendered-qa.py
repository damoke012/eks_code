#!/usr/bin/env python3
"""Verify a rendered QA overlay is what op-usxpress-qa needs. Parses YAML -- no substring
matching, no assumption about field order (kustomize sorts keys alphabetically).

    kubectl kustomize deploy/overlays/qa | python3 verify-rendered-qa.py <env>

Exit 0 = safe, 1 = not. Prints every check either way.
"""
import sys, yaml

WANT = {
    "RW_PASSWORD": "risingwave/root",
    "PG_PASSWORD": "risingwave/postgres",
    "PG_USER":     "risingwave/postgres",
}

def main():
    env = sys.argv[1] if len(sys.argv) > 1 else "qa"
    docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
    fails = []

    es = [d for d in docs if d.get("kind") == "ExternalSecret"]
    if len(es) != 1:
        print("  FAIL: expected exactly 1 ExternalSecret, found %d" % len(es)); fails.append(1)
    else:
        data = (es[0].get("spec") or {}).get("data") or []
        print("  ExternalSecret entries: %d (expected 3)" % len(data))
        seen = {}
        for d in data:
            sk = d.get("secretKey"); rk = (d.get("remoteRef") or {}).get("key", "")
            seen[sk] = rk
            ok = sk in WANT and rk.endswith(WANT[sk]) and rk.startswith("op-usxpress-%s/" % env)
            print("     %-14s <- %-42s %s" % (sk, rk, "ok" if ok else "UNEXPECTED"))
            if not ok: fails.append(1)
            # the actual thing we care about: no remoteRef still pointing at a record
            # that does not exist
            if rk.rstrip("/").endswith("entity-postgres"):
                print("     FAIL: still references the absent entity-postgres record"); fails.append(1)
        if set(seen) != set(WANT):
            print("  FAIL: keys are %s, expected %s" % (sorted(seen), sorted(WANT))); fails.append(1)

    jobs = [d for d in docs if d.get("kind") in ("Job", "CronJob")]
    for j in jobs:
        spec = j.get("spec", {})
        tmpl = spec.get("template") or spec.get("jobTemplate", {}).get("spec", {}).get("template", {})
        for c in (tmpl.get("spec") or {}).get("containers", []):
            for e in c.get("env", []) or []:
                if e.get("name", "").startswith("POSTGRES_ENTITY"):
                    src = (e.get("valueFrom") or {}).get("secretKeyRef") or {}
                    if src and not src.get("optional"):
                        print("  FAIL: Job still demands %s as a mandatory secret key" % e["name"])
                        fails.append(1)
    print("  Job env: no mandatory POSTGRES_ENTITY_* secret reference" if not fails else "")

    # informational only -- an empty ConfigMap value is fine, it is not a demand
    for d in docs:
        if d.get("kind") == "ConfigMap":
            for k, v in (d.get("data") or {}).items():
                if k.startswith("POSTGRES_") and not v:
                    print("  note: ConfigMap %s is empty -- harmless, nothing requires it" % k)

    print()
    print("VERDICT: %s" % ("SAFE TO PUSH" if not fails else "NOT SAFE -- see FAIL lines"))
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
