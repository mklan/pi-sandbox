#!/usr/bin/env bash
# pi wrapper — makes a bare `pi` respect the PI_DEFAULT_* model defaults.
#
# Installed as /home/pi/.local/bin/pi, which comes before /usr/local/bin/pi
# in PATH, so every `pi` invocation in this container (interactive shells,
# herdr panes, `herdr agent start --kind pi`, scripts) lands here first.
# The real binary is exec'd by absolute path (/usr/local/bin/pi), so there
# is no recursion.
#
# Rule (mirrors container/pi-entrypoint.sh and pi-run pi_default_flags):
# inject PI_DEFAULT_PROVIDER/MODEL/THINKING unless the caller picked a model
# or thinking level themselves. Flags passed by the caller always win.
# Management subcommands (install/remove/...) and help/version queries never
# get model flags injected — they do not accept them.
#
# Source of truth for the defaults: the PI_DEFAULT_* environment variables
# (see docker-compose.yml / docker-compose.override.yml). Leave them empty
# and this wrapper is a plain pass-through.
set -euo pipefail

REAL_PI="/usr/local/bin/pi"

# No defaults configured — plain pass-through.
if [[ -z "${PI_DEFAULT_PROVIDER:-}" && -z "${PI_DEFAULT_MODEL:-}" && -z "${PI_DEFAULT_THINKING:-}" ]]; then
  exec "$REAL_PI" "$@"
fi

# Management subcommands never take model flags — pass through untouched.
# Only the first positional argument (before `--`) can be a subcommand.
NO_INJECT_CMDS=" install remove uninstall update list config auth mcp "
pos=""
for a in "$@"; do
  [[ "$a" == "--" ]] && break
  case "$a" in
    -*) continue ;;
    *) pos="$a"; break ;;
  esac
done
if [[ -n "$pos" && "$NO_INJECT_CMDS" == *" $pos "* ]]; then
  exec "$REAL_PI" "$@"
fi

user_chose_model=0
user_chose_thinking=0
for a in "$@"; do
  [[ "$a" == "--" ]] && break
  case "$a" in
    --model|--model=*|-m|--models|--models=*) user_chose_model=1 ;;
    --thinking|--thinking=*) user_chose_thinking=1 ;;
    --help|-h|--version|-v|--list-models) exec "$REAL_PI" "$@" ;;
    --list-models=*) exec "$REAL_PI" "$@" ;;
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

exec "$REAL_PI" ${pre[@]+"${pre[@]}"} "$@"
