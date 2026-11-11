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
# The mapping comes from /proc/self/mountinfo (kernel truth:
# longest-prefix match on the mountpoint, translated through the mount's
# root field, which for host bind mounts IS the host path), so it works on
# any machine regardless of how the mounts are named. Prints the
# translated path. Exits 2 when the path lies outside every host mount.
import os
import sys

VIRTUAL_PREFIXES = ("/proc", "/sys", "/dev")


def unescape(s):
    return s.replace("\\040", " ").replace("\\011", "\t").replace("\\012", "\n").replace("\\134", "\\")


def load_mounts():
    """Return [(mountpoint, host_path)] for host-backed mounts only."""
    mounts = []
    with open("/proc/self/mountinfo") as f:
        for line in f:
            pre, _, post = line.partition(" - ")
            if not post:
                continue
            fields = pre.split()
            if len(fields) < 5:
                continue
            root, mp = unescape(fields[3]), unescape(fields[4])
            if mp == "/" or mp.startswith(VIRTUAL_PREFIXES):
                continue
            # host bind mounts show up either under /workspace (translated
            # through the root field) or as identity alias mounts
            # (mountpoint == root == host path)
            if mp.startswith("/workspace/") or (mp == root and root != "/"):
                mounts.append((mp, root))
    return mounts


def to_host(path, mounts):
    path = os.path.abspath(path)
    best = None
    for mp, src in mounts:
        if path == mp or path.startswith(mp.rstrip("/") + "/"):
            if best is None or len(mp) > len(best[0]):
                best = (mp, src)
    if best is None:
        return None
    mp, src = best
    return src + path[len(mp):]


def main():
    if len(sys.argv) != 2 or sys.argv[1] in ("-h", "--help"):
        print("usage: pi-hostpath <sandbox-path>", file=sys.stderr)
        return 2 if len(sys.argv) != 2 else 0
    host = to_host(sys.argv[1], load_mounts())
    if host is None:
        print(f"pi-hostpath: {sys.argv[1]} is not under any host mount", file=sys.stderr)
        return 2
    print(host)
    return 0


if __name__ == "__main__":
    sys.exit(main())
