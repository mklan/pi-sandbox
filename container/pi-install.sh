#!/usr/bin/env bash
# pi-install — install missing packages into the running pi sandbox and
# record them in the image Dockerfile so they are present at the next
# build. This script only makes sense *inside* the sandbox container: it is
# the one command the sandbox user may run as root (see
# /etc/sudoers.d/pi-install); it re-execs itself through sudo when needed.
#
# The Dockerfile is bind-mounted from the host at /opt/pi-service/Dockerfile
# (see docker-compose.yml), so recorded packages end up in the image
# sources on the host and are baked in at the next rebuild. Override the
# location with PI_DOCKERFILE if your setup mounts it elsewhere.
#
# Usage: pi-install <package> [package...]
set -euo pipefail

DOCKERFILE="${PI_DOCKERFILE:-/opt/pi-service/Dockerfile}"

if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo /usr/local/bin/pi-install "$@"
fi

[[ $# -gt 0 ]] || { echo "usage: pi-install <package> [package...]" >&2; exit 2; }

# strict validation: no options, no paths, no shell metacharacters
for p in "$@"; do
  [[ "$p" =~ ^[a-z0-9][a-z0-9.+-]*$ ]] \
    || { echo "pi-install: invalid package name: $p" >&2; exit 2; }
done

echo "pi-install: installing: $*"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"

if [[ ! -f "$DOCKERFILE" ]]; then
  echo "pi-install: warning: $DOCKERFILE not found — add $* to the image Dockerfile manually" >&2
  exit 0
fi

for p in "$@"; do
  # already recorded? (package lines are exactly "    <pkg> \")
  if awk -v p="$p" 'substr($0,1,4) == "    " && $1 == p { f = 1 } END { exit f ? 0 : 1 }' "$DOCKERFILE"; then
    echo "pi-install: $p already recorded in Dockerfile"
    continue
  fi
  # insert the package line directly above the cleanup line of the apt block
  PKG_LINE="    ${p} \\"
  export PKG_LINE
  awk 'index($0, "  && rm -rf /var/lib/apt/lists/") == 1 && !done \
         { print ENVIRON["PKG_LINE"]; done = 1 } \
       { print }' "$DOCKERFILE" > /tmp/pi-dockerfile.new
  # write through without replacing the inode, so the file on the host
  # keeps its owner
  cat /tmp/pi-dockerfile.new > "$DOCKERFILE"
  echo "pi-install: recorded $p in $DOCKERFILE"
done
rm -f /tmp/pi-dockerfile.new

echo "pi-install: done — the next session rebuilds the image automatically"
