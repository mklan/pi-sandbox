#!/usr/bin/env bash
# pi-sandbox installer — makes `pi-run` available everywhere.
#
# Run ON THE HOST (not in the container), from anywhere:
#   bash /path/to/pi-sandbox/install.sh [--global]
#
# Default: links ~/.local/bin/pi-run -> <this-folder>/pi-run
# --global: links /usr/local/bin/pi-run instead (needs sudo)
#
# Folder-placement independent: the target is resolved from this script's
# own location (readlink -f), so the service folder may live anywhere and
# may be renamed freely. Re-running after a move/rename repairs the link.
set -u

GLOBAL=0
[[ "${1:-}" == "--global" ]] && GLOBAL=1

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TARGET="$SCRIPT_DIR/pi-run"
[[ -x "$TARGET" ]] || { echo "install: ERROR: $TARGET not found/executable" >&2; exit 1; }

if [[ $GLOBAL -eq 1 ]]; then
  DEST="/usr/local/bin/pi-run"
  echo "installing $DEST -> $TARGET"
  sudo mkdir -p /usr/local/bin
  sudo ln -sfn "$TARGET" "$DEST"
else
  DEST="$HOME/.local/bin/pi-run"
  echo "installing $DEST -> $TARGET"
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$TARGET" "$DEST"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "NOTE: ~/.local/bin is not in PATH. Add to ~/.bashrc:"; echo '  export PATH="$HOME/.local/bin:$PATH"' ;;
  esac
fi

# --- verify ---
echo "--- verify ---"
ls -l "$DEST"
"$TARGET" help 2>&1 | head -n 5
echo
echo "done. Open a new shell (or run: hash -r) and try:  pi-run ls"
