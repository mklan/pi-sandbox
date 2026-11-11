#!/usr/bin/env python3
# pi-hostpath — translate a sandbox path to its host path.
#
# The host daemon behind /var/run/docker.sock resolves bind mounts on the
# HOST, where /workspace/... does not exist. Every /workspace/<name> is
# additionally mounted at its real host path (see
# docker-compose.override.yml.example "alias mounts"), so for any docker
# command that creates bind mounts (compose up/run, -v flags) cd to the
# REAL path instead:
#
#   cd "$(pi-hostpath /workspace/stack/services/startpage/fe/docker)"
#   ./redeploy.sh
#
# Resolution order:
#   1. daemon ground truth — ask the daemon (`docker inspect` on our own
#      container, whose id is read from the hostname bind mount in
#      /proc/self/mountinfo) for its Destination -> Source map and
#      translate through it (longest-prefix match). Source IS the host
#      path the daemon resolves, so this is exact.
#   2. kernel mount-table fallback (no docker CLI / socket) — longest-prefix
#      match on the mountpoint, translated through a same-source sibling
#      alias mount outside /workspace (mounts sharing device + root),
#      longest one wins. The raw root field is NEVER used directly: it is
#      filesystem-relative, not a host path — e.g. when the source disk is
#      mounted at /home on the host, the root shows a /matze/...-style
#      prefix that does not exist on the host and the daemon cannot see.
#
# Prints the translated path. Exits 2 when the path lies outside every
# host mount.
import json
import os
import re
import subprocess
import sys

VIRTUAL_PREFIXES = ("/proc", "/sys", "/dev")
WORKSPACE_PREFIX = "/workspace/"
SELF_ID_RE = re.compile(r"/var/lib/docker/containers/([0-9a-f]{64})/")


def unescape(s):
    return s.replace("\\040", " ").replace("\\011", "\t").replace("\\012", "\n").replace("\\134", "\\")


def load_mounts():
    """Return [(mountpoint, root, dev)] for host-backed mounts only."""
    mounts = []
    with open("/proc/self/mountinfo") as f:
        for line in f:
            pre, _, post = line.partition(" - ")
            if not post:
                continue
            fields = pre.split()
            if len(fields) < 5:
                continue
            dev, root, mp = fields[2], unescape(fields[3]), unescape(fields[4])
            if mp == "/" or mp.startswith(VIRTUAL_PREFIXES):
                continue
            # host bind mounts show up either under /workspace (translated
            # through a same-source alias below) or as alias mounts whose
            # mountpoint is itself a host path (mountpoint == root for a
            # genuine identity mount)
            if mp.startswith("/workspace/") or (mp == root and root != "/"):
                mounts.append((mp, root, dev))
    return mounts


def self_container_id():
    """Full id of our own container, via the hostname bind mount."""
    try:
        with open("/proc/self/mountinfo") as f:
            for line in f:
                m = SELF_ID_RE.search(line)
                if m:
                    return m.group(1)
    except OSError:
        pass
    return None


def daemon_mount_map(cid):
    """Return {Destination: Source} for our container, or None."""
    try:
        out = subprocess.run(
            ["docker", "inspect", cid],
            capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    try:
        mounts = json.loads(out.stdout)[0].get("Mounts", [])
        return {m["Destination"]: m["Source"] for m in mounts
                if "Destination" in m and "Source" in m}
    except (ValueError, KeyError, IndexError, TypeError):
        return None


def map_through(mapping, path):
    best = None
    for dest, src in mapping.items():
        if path == dest or path.startswith(dest.rstrip("/") + "/"):
            if best is None or len(dest) > len(best[0]):
                best = (dest, src)
    if best is None:
        return None
    dest, src = best
    return src + path[len(dest):]


def to_host_fallback(path, mounts):
    """Best-effort translation without the daemon (see header)."""
    best = None
    for mp, root, dev in mounts:
        if path == mp or path.startswith(mp.rstrip("/") + "/"):
            if best is None or len(mp) > len(best[0]):
                best = (mp, root, dev)
    if best is None:
        return None
    mp, root, dev = best
    remainder = path[len(mp):]
    # Same-source aliases (same device + root) are the same host dir seen
    # at several container paths — answer with one outside /workspace so
    # the result is daemon-valid. Longest wins (covers /home/... over a
    # stale /matze/...-style sibling).
    sibs = [smp for smp, sroot, sdev in mounts
            if sdev == dev and sroot == root
            and not smp.startswith(WORKSPACE_PREFIX)]
    if sibs:
        return max(sibs, key=len) + remainder
    return root + remainder


def main():
    if len(sys.argv) != 2 or sys.argv[1] in ("-h", "--help"):
        print("usage: pi-hostpath <sandbox-path>", file=sys.stderr)
        return 2 if len(sys.argv) != 2 else 0
    path = os.path.abspath(sys.argv[1])
    host = None
    cid = self_container_id()
    if cid is not None:
        mapping = daemon_mount_map(cid)
        if mapping:
            host = map_through(mapping, path)
    if host is None:
        try:
            mounts = load_mounts()
        except OSError:
            mounts = []
        host = to_host_fallback(path, mounts)
    if host is None:
        print(f"pi-hostpath: {sys.argv[1]} is not under any host mount", file=sys.stderr)
        return 2
    print(host)
    return 0


if __name__ == "__main__":
    sys.exit(main())
