#!/bin/bash
# Container entrypoint: apply the default provider/model/thinking level
# (PI_DEFAULT_* env vars, see docker-compose.yml), then run pi. Flags
# passed by the caller win — defaults are only added when the caller did
# not select a model themselves. Only used inside the container.
set -euo pipefail

user_chose_model=0
user_chose_thinking=0
for a in "$@"; do
  case "$a" in
    --model|--model=*|-m|--models|--models=*) user_chose_model=1 ;;
    --thinking|--thinking=*) user_chose_thinking=1 ;;
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

# gh's config dir is symlinked into the pi-agent-home volume (see
# Dockerfile) so the gh login persists — make sure the target exists.
mkdir -p /home/pi/.pi/agent/gh

exec pi "${pre[@]}" "$@"
