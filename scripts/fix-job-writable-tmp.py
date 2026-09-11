#!/usr/bin/env python3
"""Give the apply Job a writable /tmp without weakening readOnlyRootFilesystem.

  python3 fix-job-writable-tmp.py deploy/base/job.yaml

Adds an emptyDir volume, mounts it at /tmp, and sets TMPDIR. Text-level edits so the
file's comments and formatting survive; verified structurally afterwards.
"""
import sys, yaml

def main():
    path = sys.argv[1]
    src = open(path).read()

    if "readOnlyRootFilesystem: true" not in src:
        print("REFUSING: readOnlyRootFilesystem: true not found -- this is not the file I expect")
        return 4
    if "mountPath: /tmp" in src:
        print("  already has a /tmp mount -- unchanged")
        return 0

    # 1. volumeMounts on the container, immediately before its resources block
    anchor = "          resources:\n"
    if anchor not in src:
        print("REFUSING: could not find the container's resources block"); return 4
    src = src.replace(anchor,
        "          volumeMounts:\n"
        "            - name: tmp\n"
        "              mountPath: /tmp                 # apply.sh renders each file through mktemp\n"
        + anchor, 1)

    # 2. TMPDIR, so mktemp cannot pick anywhere else
    src = src.rstrip("\n") + "\n"
    src += ("            - name: TMPDIR\n"
            "              value: /tmp\n")

    # 3. the volume itself, at pod-spec level
    src += ("      volumes:\n"
            "        - name: tmp\n"
            "          emptyDir: {}                   # the root filesystem stays read-only\n")

    open(path, "w").write(src)

    # verify structurally rather than trusting the string edits
    d = yaml.safe_load(open(path).read())
    spec = d["spec"]["template"]["spec"]
    c = spec["containers"][0]
    checks = {
        "readOnlyRootFilesystem still true": c["securityContext"]["readOnlyRootFilesystem"] is True,
        "runAsNonRoot still true":           spec["securityContext"]["runAsNonRoot"] is True,
        "volume 'tmp' is an emptyDir":       any(v.get("name") == "tmp" and "emptyDir" in v for v in spec["volumes"]),
        "mounted at /tmp":                   any(m["mountPath"] == "/tmp" and m["name"] == "tmp" for m in c["volumeMounts"]),
        "TMPDIR=/tmp":                       any(e.get("name") == "TMPDIR" and e.get("value") == "/tmp" for e in c["env"]),
        "secret env untouched (3 refs)":     sum(1 for e in c["env"] if "valueFrom" in e) == 3,
    }
    ok = True
    for k, v in checks.items():
        print("  %-34s %s" % (k, "ok" if v else "FAIL"))
        ok = ok and v
    return 0 if ok else 5

if __name__ == "__main__":
    sys.exit(main())
