#!/usr/bin/env python3
"""Canonicalise a multi-doc Kubernetes render so two renders can be diffed.

  python3 scripts/normalize-k8s-render.py <file.yaml>

Emits one sorted line per leaf field, prefixed by kind/name. Comments, key
order, blank lines and document order all stop mattering; a real difference in
any field value or any present/absent field shows up as a diff line.

Why: comparing `helm template` against `kubectl kustomize` by eye or by line
count is a proxy, not the property. The question is whether a pod would see
anything different, and only a field-by-field comparison answers it.
"""
import sys, yaml

SKIP_TOP = {"status"}


def leaves(node, path, out):
    if isinstance(node, dict):
        for k in sorted(node):
            leaves(node[k], path + [str(k)], out)
    elif isinstance(node, list):
        # Index lists, but render each element's own fields so a REORDER shows
        # as a diff. Positional patches have burned us; seeing the order is the
        # point, not hiding it.
        for i, v in enumerate(node):
            leaves(v, path + ["[%d]" % i], out)
    else:
        out.append("%s = %r" % (".".join(path), node))


def main():
    if len(sys.argv) != 2:
        print("usage: normalize-k8s-render.py <file.yaml>", file=sys.stderr)
        return 2
    try:
        docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
    except yaml.YAMLError as e:
        print("ABORT: not parseable YAML: %s" % e, file=sys.stderr)
        return 3
    if not docs:
        print("ABORT: no documents - an empty render is not a match",
              file=sys.stderr)
        return 4
    lines = []
    for d in docs:
        kind = d.get("kind", "?")
        name = (d.get("metadata") or {}).get("name", "?")
        body = {k: v for k, v in d.items() if k not in SKIP_TOP}
        out = []
        leaves(body, [], out)
        lines += ["%s/%s  %s" % (kind, name, l) for l in out]
    for l in sorted(lines):
        print(l)
    print("# objects=%d fields=%d" % (len(docs), len(lines)), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
