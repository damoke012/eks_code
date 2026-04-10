#!/usr/bin/env python3
"""
Mirror a cloud Octopus release to the OnPremise space.

Reads the latest package versions from the shared S3 feed (via Octopus API)
and creates a release on the OnPremise project if that version doesn't already
exist. Does NOT deploy — deployment is manual per the feature-manual lifecycle.

Usage:
    OCTOPUS_API_KEY=API-... ./mirror-release.py [--project brands-api] [--dry-run]
    OCTOPUS_API_KEY=API-... ./mirror-release.py --all   # mirror all 6 module-coverage apps

The script reads from the cloud USXpress space's release history (read-only)
and writes only to the OnPremise space. Cloud is never modified.

Environment variables:
    OCTOPUS_API_KEY  — Octopus Deploy API key (required)
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

OCTO = "https://octopus.usxpress.io"
SRC_SPACE = "Spaces-245"   # USXpress (cloud, read-only)
DST_SPACE = "Spaces-302"   # OnPremise (write target)


def api(method, path, body=None, key=None):
    req = urllib.request.Request(
        f"{OCTO}{path}",
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            "X-Octopus-ApiKey": key,
            "Content-Type": "application/json",
        },
        method=method,
    )
    try:
        with urllib.request.urlopen(req) as r:
            data = r.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as e:
        err = e.read().decode()[:400]
        print(f"  HTTP {e.code} on {method} {path}: {err}", file=sys.stderr)
        return None


def find_project(space_id, name, key):
    d = api("GET", f"/api/{space_id}/projects?partialName={name}&take=10", key=key)
    if not d:
        return None
    for p in d.get("Items", []):
        if p["Name"] == name:
            return p
    return None


def get_latest_release(space_id, project_id, key):
    d = api("GET", f"/api/{space_id}/projects/{project_id}/releases?take=1", key=key)
    if not d or not d.get("Items"):
        return None
    return d["Items"][0]


def get_existing_releases(space_id, project_id, key, take=20):
    d = api("GET", f"/api/{space_id}/projects/{project_id}/releases?take={take}", key=key)
    if not d:
        return []
    return [r["Version"] for r in d.get("Items", [])]


def get_channel_by_name(space_id, project_id, name, key):
    d = api("GET", f"/api/{space_id}/projects/{project_id}/channels?take=20", key=key)
    if not d:
        return None
    for c in d.get("Items", []):
        if c["Name"] == name:
            return c
    return None


def mirror_release(project_name, key, dry_run=False):
    print(f"\n{'='*60}")
    print(f"Mirroring: {project_name}")
    print(f"  source: USXpress ({SRC_SPACE})")
    print(f"  target: OnPremise ({DST_SPACE})")

    # 1. Find source project + latest release
    src_proj = find_project(SRC_SPACE, project_name, key)
    if not src_proj:
        print(f"  ERROR: project {project_name!r} not found in USXpress space")
        return False

    latest = get_latest_release(SRC_SPACE, src_proj["Id"], key)
    if not latest:
        print(f"  ERROR: no releases found for {project_name} in USXpress")
        return False

    version = latest["Version"]
    packages = latest.get("SelectedPackages", [])
    print(f"  latest cloud release: {version}")
    for sp in packages:
        print(f"    {sp.get('PackageReferenceName','?'):12} = {sp.get('Version','?')}")

    # 2. Find target project
    dst_proj = find_project(DST_SPACE, project_name, key)
    if not dst_proj:
        print(f"  ERROR: project {project_name!r} not found in OnPremise space")
        print(f"         (run Bento import first — see INFRA-1453)")
        return False

    # 3. Check if this version already exists in OnPremise
    existing = get_existing_releases(DST_SPACE, dst_proj["Id"], key)
    if version in existing:
        print(f"  SKIP: version {version} already exists in OnPremise")
        return True

    # 4. Find the release channel in OnPremise
    channel = get_channel_by_name(DST_SPACE, dst_proj["Id"], "release", key)
    if not channel:
        print(f"  ERROR: 'release' channel not found in OnPremise project")
        return False

    # 5. Create release
    release_body = {
        "ProjectId": dst_proj["Id"],
        "ChannelId": channel["Id"],
        "Version": version,
        "SelectedPackages": packages,
    }

    if dry_run:
        print(f"  DRY-RUN: would create release {version} on OnPremise/{project_name}")
        print(f"           channel={channel['Name']} ({channel['Id']})")
        return True

    result = api("POST", f"/api/{DST_SPACE}/releases", body=release_body, key=key)
    if not result:
        print(f"  ERROR: release creation failed")
        return False

    print(f"  CREATED: release {result.get('Id')} version {result.get('Version')}")
    print(f"  Deploy manually via Octopus UI: OnPremise > {project_name} > Releases > Deploy to development")
    return True


def main():
    ap = argparse.ArgumentParser(description="Mirror cloud Octopus releases to OnPremise space")
    ap.add_argument("--project", "-p", default="brands-api",
                    help="Project name to mirror (default: brands-api)")
    ap.add_argument("--all", action="store_true",
                    help="Mirror all 6 module-coverage apps")
    ap.add_argument("--dry-run", action="store_true",
                    help="Preview without creating releases")
    args = ap.parse_args()

    key = os.environ.get("OCTOPUS_API_KEY")
    if not key:
        sys.exit("OCTOPUS_API_KEY not set")

    projects = [
        "brands-api",
        "geoenrichment-sync-handler",
        "attrition-api",
        "io-notifications-handler",
        "trailers-api",
        "safetylytx-video-api",
    ] if args.all else [args.project]

    ok = 0
    fail = 0
    for name in projects:
        if mirror_release(name, key, args.dry_run):
            ok += 1
        else:
            fail += 1

    print(f"\nDone: {ok} ok, {fail} failed")
    if fail > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
