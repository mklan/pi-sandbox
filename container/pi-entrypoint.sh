#!/bin/bash
# Container entrypoint: prepare the persistent bits (volume dirs, herdr
# config + pi integration), then run the container's main process.
#
#   pi-entrypoint             -> herdr server: keeps every pane, agent and
#                                command in this container running
#   pi-entrypoint pi [args]   -> pi, with the PI_DEFAULT_* defaults applied
#   pi-entrypoint <cmd> ...   -> run <cmd> as-is (e.g. bash)
#
# Flags passed to pi win — defaults are only added when the caller did not
# select a model themselves. Only used inside the container.
set -euo pipefail

# gh's config dir is symlinked into the pi-agent-home volume (see
# Dockerfile) so the gh login persists — make sure the target exists.
mkdir -p /home/pi/.pi/agent/gh

# herdr's state (config, workspace layout, session snapshots, logs,
# sockets) lives in the volume too (same symlink trick), so workspaces and
# agents come back after the container is recreated. Stale sockets from a
# dead container are picked up by the next server start on their own.
mkdir -p /home/pi/.pi/agent/herdr

# first run: skip herdr's onboarding wizard — the pi integration installed
# below is exactly what that wizard would set up.
if [[ ! -e /home/pi/.config/herdr/config.toml ]]; then
  printf '# seeded by pi-entrypoint — see container/AGENTS.md\nonboarding = false\n' \
    > /home/pi/.config/herdr/config.toml
fi

# pi agent integration: reports working/blocked/done status to herdr and
# enables native pi session restore (installer is idempotent).
herdr integration install pi >/dev/null 2>&1 || true

# pi extensions declared in container/pi-extensions.txt (baked into the
# image, overlaid by the compose bind-mount so host edits are visible):
# declare + install whatever is missing. No-op when nothing changed, and
# never fatal — pi itself retries a failed package install on next start.
if command -v pi-extensions-sync >/dev/null 2>&1; then
  pi-extensions-sync || echo "pi-entrypoint: warning: extension sync had failures" >&2
fi

# pi default-model wrapper: /home/pi/.local/bin/pi shadows the real
# /usr/local/bin/pi (first in PATH) so a bare `pi` in any herdr pane
# respects PI_DEFAULT_* — not just workspaces opened via pi-run.
# (Re)installed on every boot so host edits to container/pi-wrapper.sh
# (compose bind-mount) take effect on restart even before the next rebuild
# bakes them in. Never fatal — worst case a bare `pi` uses pi's own default.
if [[ -f /opt/pi-service/pi-wrapper.sh ]]; then
  cp /opt/pi-service/pi-wrapper.sh /home/pi/.local/bin/pi 2>/dev/null \
    && chmod 0755 /home/pi/.local/bin/pi 2>/dev/null || true
fi

# pi-worktree helper (see container/pi-worktree.sh): (re)installed to PATH
# on every boot so host edits via the compose bind-mount take effect on
# restart even before the next rebuild bakes them in. Never fatal.
if [[ -f /opt/pi-service/pi-worktree.sh ]]; then
  cp /opt/pi-service/pi-worktree.sh /usr/local/bin/pi-worktree 2>/dev/null \
    && chmod 0755 /usr/local/bin/pi-worktree 2>/dev/null || true
fi

# pi-hostpath helper (see container/pi-hostpath.sh): same reinstall deal.
# Never fatal.
if [[ -f /opt/pi-service/pi-hostpath.sh ]]; then
  cp /opt/pi-service/pi-hostpath.sh /usr/local/bin/pi-hostpath 2>/dev/null \
    && chmod 0755 /usr/local/bin/pi-hostpath 2>/dev/null || true
fi

# Docker socket (opt-in via docker-compose.override.yml): point at the fix
# when `docker ps` fails, instead of leaving a permission mystery.
if [[ ! -S /var/run/docker.sock ]]; then
  echo "pi-entrypoint: note: no docker socket mounted — enable it in docker-compose.override.yml for e2e tests (see README)" >&2
fi

if [[ $# -eq 0 ]]; then
  # the container's main process: herdr owns every terminal here and keeps
  # it running until the container stops. Clients attach with `herdr`
  # (pi-run does that from the host).
  exec herdr server
fi

if [[ "$1" == pi ]]; then
  shift
  # Management subcommands never take model flags — pass through untouched.
  # (Mirrors container/pi-wrapper.sh; keep the two in sync.)
  pos=""
  for a in "$@"; do
    [[ "$a" == "--" ]] && break
    case "$a" in
      -*) continue ;;
      *) pos="$a"; break ;;
    esac
  done
  case " $pos " in
    *" install "*|*" remove "*|*" uninstall "*|*" update "*|*" list "*|*" config "*|*" auth "*|*" mcp "*)
      exec /usr/local/bin/pi "$@" ;;
  esac
  user_chose_model=0
  user_chose_thinking=0
  for a in "$@"; do
    [[ "$a" == "--" ]] && break
    case "$a" in
      --model|--model=*|-m|--models|--models=*) user_chose_model=1 ;;
      --thinking|--thinking=*) user_chose_thinking=1 ;;
      --help|-h|--version|-v|--list-models|--list-models=*) exec /usr/local/bin/pi "$@" ;;
    esac
  done

  pre=()
  if [[ $user_chose_model -eq 0 ]]; then
    # a caller-provided model may belong to another provider, so the default
    # provider is only paired with the default model
    [[ -n "${PI_DEFAULT_PROVIDER:-}" ]] && pre+=(--provider "$PI_DEFAULT_PROVIDER")
    [[ -n "${PI_DEFAULT_MODEL:-}" ]] && pre+=(--model "$PI_DEFAULT_MODEL")
  fi
  if [[ $user_chose_thinking -eq 0 && -n "${PI_DEFAULT_THINKING:-}" ]]; then
    pre+=(--thinking "$PI_DEFAULT_THINKING")
  fi

  exec /usr/local/bin/pi ${pre[@]+"${pre[@]}"} "$@"
fi

exec "$@"
