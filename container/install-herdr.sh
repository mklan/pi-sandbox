#!/bin/sh
# install-herdr.sh — build-time installer for the herdr TUI (herdr.dev).
#
# herdr is pinned in the image like pi (ARG HERDR_VERSION in the
# Dockerfile): this script bakes a pinned release into the next build,
# while `herdr update` inside a running session only changes that
# container. The download is checksum-verified against the same release
# manifest herdr's own installer uses.
#
# Usage: install-herdr.sh <version> <install-dir>
set -eu

VERSION="${1:?usage: install-herdr.sh <version> <install-dir>}"
DIR="${2:?usage: install-herdr.sh <version> <install-dir>}"
BIN=herdr
MANIFEST_URL="https://herdr.dev/latest.json"

case "$(uname -m)" in
  x86_64|amd64)  arch=x86_64 ;;
  aarch64|arm64) arch=aarch64 ;;
  *) echo "install-herdr: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
TARGET="${HERDR_TARGET:-linux-${arch}}"

echo "install-herdr: herdr ${VERSION} for ${TARGET}"
manifest="$(curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 "$MANIFEST_URL")"
url="$(printf '%s' "$manifest" \
  | jq -r --arg v "$VERSION" --arg t "$TARGET" '.releases[$v].assets[$t] // empty')"
sha="$(printf '%s' "$manifest" \
  | jq -r --arg v "$VERSION" --arg t "$TARGET" '.releases[$v].sha256[$t] // empty')"

if [ -z "$url" ]; then
  # not listed in the manifest any more (older release) — try GitHub directly
  url="https://github.com/herdrdev/herdr/releases/download/v${VERSION}/herdr-${TARGET}"
  echo "install-herdr: not in manifest, trying $url"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL --retry 3 --connect-timeout 10 --max-time 300 "$url" -o "$tmp"

if [ -n "$sha" ]; then
  printf '%s  %s\n' "$sha" "$tmp" | sha256sum -c - >/dev/null \
    || { echo "install-herdr: checksum mismatch for $url" >&2; exit 1; }
else
  echo "install-herdr: warning: no checksum for this release — not verified" >&2
fi

mkdir -p "$DIR"
install -m 0755 "$tmp" "$DIR/$BIN"
echo "install-herdr: installed $("$DIR/$BIN" --version) to $DIR/$BIN"
