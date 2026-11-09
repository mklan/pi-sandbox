#!/usr/bin/env bash
# pi-extensions-sync — install the pi extensions declared in
# container/pi-extensions.txt (see that file for the format).
#
# Reads the desired sources from $PI_EXTENSIONS_FILE
# (/opt/pi-service/pi-extensions.txt by default — baked into the image and
# overlaid by the compose bind-mount, so host edits are visible), compares
# them with the `packages` declared in the pi settings, and runs
# `pi install <source>` for whatever is missing (pi install also records
# the source in settings, so this is idempotent).
#
# Runs as the pi user, at image build time (bakes extensions into the
# image) and at container boot (pi-entrypoint.sh, picks up added lines).
# Never fatal: a failed install (e.g. offline) only warns — pi itself
# retries missing packages on its next start.
#
# Usage: pi-extensions-sync
set -euo pipefail

LIST="${PI_EXTENSIONS_FILE:-/opt/pi-service/pi-extensions.txt}"
SETTINGS="${PI_SETTINGS_FILE:-/home/pi/.pi/agent/settings.json}"

[[ -f "$LIST" ]] || exit 0

# desired sources: strip comments/whitespace, drop blanks
mapfile -t WANT < <(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$LIST" | grep -v '^$' || true)
[[ ${#WANT[@]} -gt 0 ]] || exit 0

# sources already declared in settings.json (plain strings and {source} objects)
HAVE=""
if [[ -f "$SETTINGS" ]]; then
  HAVE="$(python3 - "$SETTINGS" <<'EOF' || true
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
pkgs = data.get("packages", []) if isinstance(data, dict) else []
for p in pkgs or []:
    if isinstance(p, str):
        print(p)
    elif isinstance(p, dict) and isinstance(p.get("source"), str):
        print(p["source"])
EOF
)"
fi

failed=0
for src in "${WANT[@]}"; do
  # sanity check: a pi package source is one token (npm:/git:/URL/path) —
  # never shell metacharacters or whitespace
  if [[ ! "$src" =~ ^[A-Za-z0-9@._+/:~=-]+$ || "$src" == *".."* ]]; then
    echo "pi-extensions-sync: warning: skipping invalid source: $src" >&2
    continue
  fi
  if printf '%s\n' "$HAVE" | grep -qxF -- "$src"; then
    continue
  fi
  echo "pi-extensions-sync: installing $src ..."
  if command -v timeout >/dev/null 2>&1; then
    timeout 180 pi install "$src" || { echo "pi-extensions-sync: warning: install failed for $src (pi retries it on next start)" >&2; failed=1; continue; }
  else
    pi install "$src" || { echo "pi-extensions-sync: warning: install failed for $src (pi retries it on next start)" >&2; failed=1; continue; }
  fi
  HAVE="$(printf '%s\n%s' "$HAVE" "$src")"
done

exit "$failed"
