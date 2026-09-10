#!/usr/bin/env python3
"""Resolve an on-prem cluster to (kubeconfig file, context) BY ENDPOINT.

    python3 scripts/kube-resolve-onprem.py qa    ->  <file>\t<context>

Never trust a kubeconfig filename, and never trust that a file matching an endpoint
has that endpoint as its CURRENT context -- merged files hold several clusters and
prod is one `use-context` away. This resolves a context whose cluster.server is the
requested endpoint, prints exactly one, and stops.
"""
import os, sys, glob, json, subprocess

ENDPOINT = {
    "dev":  "10.10.82.50",
    "qa":   "10.10.82.51",
    "prod": "10.10.82.52",
}

def candidates():
    seen = []
    for p in (os.environ.get("KUBECONFIG") or "").split(os.pathsep):
        if p and os.path.isfile(p):
            seen.append(p)
    home = os.path.expanduser("~/.kube")
    for pat in ("*.yaml", "*.yml", "*.conf", "config"):
        for p in sorted(glob.glob(os.path.join(home, pat))):
            if os.path.isfile(p):
                seen.append(p)
    out = []
    for p in seen:
        if p not in out:
            out.append(p)
    return out

def resolve(env):
    want = ENDPOINT[env]
    hits = []
    for path in candidates():
        # kubectl parses it -- no PyYAML dependency, and no hand-rolled YAML
        try:
            out = subprocess.run(
                ["kubectl", "--kubeconfig", path, "config", "view", "-o", "json"],
                capture_output=True, text=True, timeout=20)
            doc = json.loads(out.stdout) if out.returncode == 0 else {}
        except Exception:
            continue
        servers = {}
        for c in (doc.get("clusters") or []):
            name = c.get("name")
            srv = ((c.get("cluster") or {}).get("server") or "")
            if name:
                servers[name] = srv
        for ctx in (doc.get("contexts") or []):
            cname = ((ctx.get("context") or {}).get("cluster"))
            srv = servers.get(cname, "")
            # match the ENDPOINT, on this context's own cluster -- not "the file
            # contains it somewhere"
            if want in srv:
                hits.append((path, ctx.get("name"), srv))
    return hits

def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ENDPOINT:
        print("usage: kube-resolve-onprem.py dev|qa|prod", file=sys.stderr)
        return 2
    env = sys.argv[1]
    hits = resolve(env)
    if not hits:
        print("NO CONTEXT serves %s (%s) in any kubeconfig on this machine."
              % (ENDPOINT[env], env), file=sys.stderr)
        print("Files searched:", file=sys.stderr)
        for p in candidates():
            print("  " + p, file=sys.stderr)
        return 4
    path, ctx, srv = hits[0]
    if len(hits) > 1:
        print("note: %d contexts serve %s; using the first."
              % (len(hits), ENDPOINT[env]), file=sys.stderr)
        for p, c, s in hits:
            print("      %s  [%s]" % (c, p), file=sys.stderr)
    print("%s\t%s\t%s" % (path, ctx, srv))
    return 0

if __name__ == "__main__":
    sys.exit(main())
