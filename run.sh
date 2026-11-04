#!/usr/bin/env bash
# pi session manager — run pi in a sandboxed container per folder, with
# named sessions you can detach from and re-attach to, so several folders
# can work in parallel.
#
#   ./run.sh [-b] [path] [pi-args...]   open (or re-attach to) pi for a folder
#   ./run.sh ls [-w]                    list sessions (-w: live view)
#   ./run.sh log <path|name>            show a session's current screen
#   ./run.sh shell [path|name] [cmd...]  bash in the folder's container
#   ./run.sh kill <path|name|--all>     stop one or all sessions
#   ./run.sh upgrade [version]          pin pi in the Dockerfile and rebuild
#   ./run.sh help                       this text
#
# Sessions are tmux sessions named pi-<folder>. Detach with your tmux
# prefix + d (default: Ctrl-b d) — pi keeps running in the background.
#
# Paths may be host paths or container paths (/workspace/...) and must lie
# inside one of the folders mounted under /workspace. Which folders those
# are is configured in docker-compose.yml / docker-compose.override.yml
# and discovered here from the merged compose config — add a mount and it
# becomes a valid session folder. A bare folder name works too when it is
# unambiguous (a folder directly under one of the mounts, or an existing
# session name). -b/--background starts the session without attaching.
set -euo pipefail

SERVICE_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

die() { printf 'run.sh: %s\n' "$*" >&2; exit 1; }

usage() {
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

need_tmux() { command -v tmux >/dev/null 2>&1 || die "tmux is required"; }

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

hash4() { printf '%s' "$1" | cksum | awk '{ printf "%04x", $1 % 65536 }'; }

# --- workspace mounts ----------------------------------------------------
# The folders the agent may work in are exactly the bind mounts under
# /workspace in the effective compose config (docker-compose.yml merged
# with docker-compose.override.yml). Discovering them there keeps the
# compose files the single source of truth.
M_HOST=()
M_CTR=()
mounts_loaded=0

load_mounts() {
  [[ $mounts_loaded -eq 1 ]] && return
  mounts_loaded=1
  local cfg pairs host ctr
  cfg="$(cd "$SERVICE_DIR" && docker compose config)" \
    || die "cannot read the docker compose config in $SERVICE_DIR"
  # pull "host<tab>container" pairs for bind mounts with a /workspace target
  # out of the normalized config (service volumes section, long syntax)
  pairs="$(printf '%s\n' "$cfg" | awk '
    /^    volumes:$/       { vol = 1; next }
    vol && /^    [a-z_]/   { vol = 0 }
    !vol                   { next }
    /- type: / {
      if (type == "bind" && src ~ "^/" && tgt ~ "^/workspace") print src "\t" tgt
      type = $3; src = ""; tgt = ""; next
    }
    /^ +source: /          { src = $2 }
    /^ +target: /          { tgt = $2 }
    END {
      if (type == "bind" && src ~ "^/" && tgt ~ "^/workspace") print src "\t" tgt
    }')"
  while IFS=$'\t' read -r host ctr; do
    [[ -n "$host" && -n "$ctr" ]] || continue
    M_HOST+=("$host")
    M_CTR+=("$ctr")
  done <<< "$pairs"
  [[ ${#M_HOST[@]} -gt 0 ]] \
    || die "no folders mounted under /workspace — add some in docker-compose.yml or docker-compose.override.yml"
}

joined_hosts() { load_mounts; local IFS=', '; printf '%s' "${M_HOST[*]}"; }
joined_ctrs()  { load_mounts; local IFS=', '; printf '%s' "${M_CTR[*]}"; }

# find the mount a path belongs to (longest match wins); prints
# "host<tab>container".
mount_for_host() {
  local p="$1" i best=-1
  load_mounts
  for i in "${!M_HOST[@]}"; do
    case "$p" in
      "${M_HOST[$i]}"|"${M_HOST[$i]}"/*)
        if [[ $best -lt 0 || ${#M_HOST[$i]} -gt ${#M_HOST[$best]} ]]; then best=$i; fi ;;
    esac
  done
  if [[ $best -ge 0 ]]; then
    printf '%s\t%s\n' "${M_HOST[$best]}" "${M_CTR[$best]}"
  fi
  return 0
}

mount_for_ctr() {
  local p="$1" i best=-1
  load_mounts
  for i in "${!M_CTR[@]}"; do
    case "$p" in
      "${M_CTR[$i]}"|"${M_CTR[$i]}"/*)
        if [[ $best -lt 0 || ${#M_CTR[$i]} -gt ${#M_CTR[$best]} ]]; then best=$i; fi ;;
    esac
  done
  if [[ $best -ge 0 ]]; then
    printf '%s\t%s\n' "${M_HOST[$best]}" "${M_CTR[$best]}"
  fi
  return 0
}

# canonical host path from user input (host path, container path, or .)
host_path() {
  load_mounts
  local p="${1:-.}" abs m mh mc cand i
  local matches=()
  case "$p" in
    /workspace|/workspace/*)
      m="$(mount_for_ctr "$p")"
      [[ -n "$m" ]] || die "$p is not a mounted folder (mounted: $(joined_ctrs))"
      IFS=$'\t' read -r mh mc <<<"$m"
      p="$mh${p#"$mc"}"
      ;;
  esac
  abs="$(realpath -m "$p")"
  if [[ ! -d "$abs" && "$p" != */* && "$p" != /* ]]; then
    # bare folder name: look for it directly under one of the mounts
    for i in "${!M_HOST[@]}"; do
      cand="${M_HOST[$i]}/$p"
      if [[ -d "$cand" ]]; then
        matches+=("$(realpath -m "$cand")")
      fi
    done
    if [[ ${#matches[@]} -eq 1 ]]; then
      abs="${matches[0]}"
    elif [[ ${#matches[@]} -gt 1 ]]; then
      die "ambiguous folder name '$p': ${matches[*]}"
    fi
  fi
  [[ -d "$abs" ]] || die "not a directory: $p"
  m="$(mount_for_host "$abs")"
  [[ -n "$m" ]] || die "outside the mounted folders ($(joined_hosts)): $abs"
  printf '%s' "$abs"
}

container_path() {
  local m mh mc
  m="$(mount_for_host "$1")"
  [[ -n "$m" ]] || return 0
  IFS=$'\t' read -r mh mc <<<"$m"
  printf '%s%s' "$mc" "${1#"$mh"}"
}

session_name() {
  local abs="$1" slug cand stored
  slug="$(slugify "$(basename "$abs")")"
  cand="pi-${slug:-root}"
  if tmux has-session -t "=$cand" 2>/dev/null; then
    stored="$(tmux show-options -qv -t "$cand" @pi-path 2>/dev/null || true)"
    if [[ -n "$stored" && "$stored" != "$abs" ]]; then
      cand="pi-$slug-$(hash4 "$abs")"
    fi
  fi
  printf '%s' "$cand"
}

# resolve "<path|name>" to "name<tab>host-abs-path"
lookup() {
  local arg="${1:-.}" name abs
  if [[ "$arg" == pi-* ]] && tmux has-session -t "=$arg" 2>/dev/null; then
    name="$arg"
  elif tmux has-session -t "=pi-$arg" 2>/dev/null; then
    name="pi-$arg"
  else
    abs="$(host_path "$arg")"
    printf '%s\t%s\n' "$(session_name "$abs")" "$abs"
    return
  fi
  abs="$(tmux show-options -qv -t "$name" @pi-path 2>/dev/null || true)"
  printf '%s\t%s\n' "$name" "$abs"
}

attach() {
  local name="$1"
  echo "session $name — detach with: tmux prefix + d (default Ctrl-b d)"
  if [[ -n "${TMUX:-}" ]]; then
    exec tmux switch-client -t "$name"
  else
    exec tmux attach-session -t "$name"
  fi
}

# The image is self-extending: pi-install records newly needed packages in
# the Dockerfile. A stamp label in the image lets us detect that the image
# no longer matches its sources and rebuild before starting a session.
image_stamp() {
  sha256sum "$SERVICE_DIR/container/Dockerfile" "$SERVICE_DIR/container/pi-install.sh" "$SERVICE_DIR/container/pi-entrypoint.sh" 2>/dev/null \
    | sha256sum | cut -c1-16
}

ensure_image() {
  local want have
  want="$(image_stamp)"
  have="$(docker image inspect pi-sandbox -f '{{ index .Config.Labels "pi.service.stamp" }}' 2>/dev/null || true)"
  if [[ "$want" != "$have" ]]; then
    echo "pi-sandbox image out of date (Dockerfile/scripts changed) — rebuilding..."
    (cd "$SERVICE_DIR" && docker compose build --build-arg PI_STAMP="$want")
  fi
}

create() {
  local name="$1" abs="$2"
  shift 2
  local cdir cmd a
  cdir="$(container_path "$abs")"
  ensure_image
  # stale container from a previous session
  docker rm -f "$name" >/dev/null 2>&1 || true
  cmd="docker compose run --rm --name $(printf '%q' "$name") -w $(printf '%q' "$cdir") pi"
  for a in "$@"; do cmd+=" $(printf '%q' "$a")"; done
  tmux new-session -d -s "$name" -c "$SERVICE_DIR" "$cmd"
  tmux set-option -t "$name" @pi-path "$abs"
  tmux set-option -t "$name" @pi-cname "$name"
}

cmd_open() {
  need_tmux
  local bg=0 path
  while [[ "${1:-}" == -b || "${1:-}" == --background ]]; do
    bg=1
    shift
  done
  if [[ $# -gt 0 && "$1" != -* ]]; then
    path="$1"
    shift
  else
    path="."
  fi
  local abs name
  IFS=$'\t' read -r name abs < <(lookup "$path") || true
  [[ -n "$abs" ]] || die "unknown session or folder: $path"
  if tmux has-session -t "=$name" 2>/dev/null; then
    [[ $# -gt 0 ]] && echo "note: session exists, pi args ignored" >&2
  else
    create "$name" "$abs" "$@"
  fi
  if [[ $bg -eq 1 ]]; then
    echo "started $name ($abs)"
  else
    attach "$name"
  fi
}

# display form: the container path minus the /workspace prefix, e.g.
# "stack/services/pi"
short_path() {
  local m mh mc
  m="$(mount_for_host "$1")"
  if [[ -z "$m" ]]; then printf '%s' "$1"; return 0; fi
  IFS=$'\t' read -r mh mc <<<"$m"
  printf '%s%s' "${mc#/workspace/}" "${1#"$mh"}"
}

age_str() {
  local s=$(( $(date +%s) - $1 ))
  if   (( s < 60 ));    then printf '%ds' "$s"
  elif (( s < 3600 ));  then printf '%dm' "$((s / 60))"
  elif (( s < 86400 )); then printf '%dh%02dm' "$((s / 3600))" "$((s % 3600 / 60))"
  else                     printf '%dd%02dh' "$((s / 86400))" "$((s % 86400 / 3600))"
  fi
}

# last meaningful line currently on the session's pane — a quick peek at
# what pi is showing right now (status/percentage lines are skipped)
last_output() {
  tmux capture-pane -p -t "$1" 2>/dev/null \
    | sed 's/[[:space:]]*$//' \
    | awk 'NF && $0 !~ /^[0-9.]+%\/[0-9]/ { l = $0 } END { print l }' \
    | cut -c1-44
}

ls_table() {
  local s created abs attached state
  printf '%-18s %-28s %-9s %-6s %s\n' SESSION FOLDER STATE AGE LAST
  while IFS=$'\t' read -r s created abs attached; do
    if [[ "${attached:-0}" -gt 0 ]]; then state="attached"; else state="detached"; fi
    printf '%-18s %-28s %-9s %-6s %s\n' "$s" "$(short_path "${abs:-?}")" \
      "$state" "$(age_str "$created")" "$(last_output "$s")"
  done < <(tmux list-sessions -F $'#{session_name}\t#{session_created}\t#{@pi-path}\t#{session_attached}' 2>/dev/null \
    | grep '^pi-' || true)
}

cmd_ls() {
  need_tmux
  local watch=0
  if [[ "${1:-}" == "-w" || "${1:-}" == "--watch" ]]; then watch=1; fi
  while true; do
    if [[ $watch -eq 1 ]]; then
      clear
      echo "pi sessions — $(date '+%Y-%m-%d %H:%M:%S') — ctrl+c to stop watching"
      echo
    fi
    ls_table
    if [[ $watch -eq 0 ]]; then break; fi
    sleep 2
  done
}

cmd_log() {
  need_tmux
  local name abs
  IFS=$'\t' read -r name abs < <(lookup "${1:-.}") || true
  tmux has-session -t "=$name" 2>/dev/null || die "no session for ${1:-$PWD}"
  tmux capture-pane -p -t "$name" -S -300
}

kill_one() {
  local name="$1" cname
  cname="$(tmux show-options -qv -t "$name" @pi-cname 2>/dev/null || true)"
  tmux kill-session -t "$name" 2>/dev/null || true
  docker rm -f "${cname:-$name}" >/dev/null 2>&1 || true
  echo "stopped $name"
}

cmd_kill() {
  need_tmux
  if [[ "${1:-}" == "--all" ]]; then
    local s
    while IFS= read -r s; do
      kill_one "$s"
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^pi-' || true)
  else
    local name abs
    IFS=$'\t' read -r name abs < <(lookup "${1:-.}") || true
    tmux has-session -t "=$name" 2>/dev/null || die "no session for ${1:-$PWD}"
    kill_one "$name"
  fi
}

cmd_shell() {
  need_tmux
  local name abs cdir
  if [[ $# -gt 0 && "$1" != -* ]]; then
    IFS=$'\t' read -r name abs < <(lookup "$1") || true
    shift
  else
    IFS=$'\t' read -r name abs < <(lookup ".") || true
  fi
  [[ -n "$abs" ]] || die "unknown session: ${1:-}"
  cdir="$(container_path "$abs")"
  if docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true; then
    local tflags="-i"
    [[ -t 0 ]] && tflags="-it"
    exec docker exec "$tflags" -w "$cdir" "$name" bash "$@"
  fi
  echo "no running container for $name — starting an ephemeral shell"
  ensure_image
  cd "$SERVICE_DIR"
  exec docker compose run --rm -w "$cdir" --entrypoint bash pi "$@"
}

# Pin a pi version in the Dockerfile and rebuild. Without a version it
# pins the latest release from the npm registry. This is persistent: the
# version lives in the Dockerfile like every other image property, so all
# future builds keep it. (`pi update` inside a session is NOT — it only
# changes the throwaway container.)
cmd_upgrade() {
  local ver="${1:-}" old
  if [[ -z "$ver" ]]; then
    command -v npm >/dev/null 2>&1 \
      || die "npm not found on the host — pass a version: ./run.sh upgrade <version>"
    if ! ver="$(npm view @earendil-works/pi-coding-agent version 2>/dev/null)"; then
      die "could not query npm for the latest version"
    fi
  fi
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+-][A-Za-z0-9.+-]*)?$ ]] \
    || die "invalid version: $ver"
  old="$(sed -n 's/^ARG PI_VERSION=//p' "$SERVICE_DIR/container/Dockerfile")"
  if [[ "$old" == "$ver" ]]; then
    echo "pi already pinned to $ver in Dockerfile"
  else
    sed -i "s/^ARG PI_VERSION=.*/ARG PI_VERSION=${ver}/" "$SERVICE_DIR/container/Dockerfile"
    echo "pi pinned to $ver in Dockerfile (was ${old:-unset})"
  fi
  ensure_image
  echo "done — new sessions run pi $ver"
}

case "${1:-}" in
  ""|open) shift 2>/dev/null || true; cmd_open "$@" ;;
  ls|list|ps) cmd_ls ;;
  log|peek) shift; cmd_log "$@" ;;
  shell|sh|bash) shift; cmd_shell "$@" ;;
  kill|stop|rm) shift; cmd_kill "$@" ;;
  upgrade|up|update) shift; cmd_upgrade "$@" ;;
  help|-h|--help) usage ;;
  *) cmd_open "$@" ;;
esac
