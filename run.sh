#!/usr/bin/env bash
# pi sandbox launcher — one herdr inside the container, one shortcut on
# the host.
#
#   ./run.sh [-b]                       open herdr for the current folder
#   ./run.sh [-b] [path] [pi-args...]   open herdr on the folder's workspace
#   ./run.sh ls [-w]                    list workspaces and agents (-w: live)
#   ./run.sh log <path|name>            show a workspace's current screen
#   ./run.sh shell [path|name] [cmd...] bash in the sandbox at the folder
#   ./run.sh kill <path|name|--all>     close one or all workspaces
#   ./run.sh down                       stop the sandbox (everything stops)
#   ./run.sh upgrade [version]          pin pi in the Dockerfile and rebuild
#   ./run.sh upgrade-herdr [version]    pin herdr in the Dockerfile and rebuild
#   ./run.sh help                       this text
#
# The sandbox container runs herdr (herdr.dev) as its main process. herdr
# is a terminal workspace manager for coding agents: one workspace per
# folder, every pane/agent/command kept alive by the herdr server inside
# the container — independent of your SSH connection, this script, or any
# TUI client. No tmux involved anywhere.
#
# This script is only a convenience layer: it makes sure the container and
# its herdr server are up, opens (or creates) the workspace for a folder,
# focuses it, and drops you into the herdr TUI. First open of a folder
# starts pi in its workspace (with the PI_DEFAULT_* model defaults, like
# before); everything that runs there keeps running until you close it.
#
# Inside the TUI: detach with ctrl+b q — panes and agents keep working.
# Re-attach by running this script again (any folder, or none for the
# current one). Press ctrl+b then ? in the TUI for all keys, or use the
# mouse: herdr is mouse-first.
#
# Paths may be host paths or container paths (/workspace/...) and must lie
# inside one of the folders mounted under /workspace. Which folders those
# are is configured in docker-compose.yml / docker-compose.override.yml
# and discovered here from the merged compose config — add a mount and it
# becomes a valid workspace folder. A bare folder name works too when it is
# unambiguous (any folder under one of the mounts is found by name), and so
# does a workspace name (its label) or id (w1, w2, ...). With no path at
# all, run.sh opens the current folder; from outside the mounts it just
# attaches wherever you left off.
set -euo pipefail

SERVICE_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

err() { printf 'run.sh: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

usage() {
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

# workspace names must be safe in labels and CLI args
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9_-]/-/g; s/--*/-/g; s/^-//; s/-$//'
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
      [[ -n "$m" ]] || { err "$p is not a mounted folder (mounted: $(joined_ctrs))"; return 1; }
      IFS=$'\t' read -r mh mc <<<"$m"
      p="$mh${p#"$mc"}"
      ;;
  esac
  abs="$(realpath -m "$p")"
  if [[ ! -d "$abs" && "$p" != */* && "$p" != /* ]]; then
    # bare folder name: look for it under one of the mounts — first as a
    # direct child of a mount root, then anywhere below (bounded depth,
    # skipping hidden folders and node_modules)
    for i in "${!M_HOST[@]}"; do
      cand="${M_HOST[$i]}/$p"
      [[ -d "$cand" ]] && matches+=("$(realpath -m "$cand")")
    done
    if [[ ${#matches[@]} -eq 0 ]]; then
      for i in "${!M_HOST[@]}"; do
        while IFS= read -r cand; do
          matches+=("$(realpath -m "$cand")")
        done < <(find "${M_HOST[$i]}" -maxdepth 4 \
          \( -name '.*' -o -name node_modules \) -prune \
          -o -type d -name "$p" -print 2>/dev/null)
      done
    fi
    if [[ ${#matches[@]} -gt 1 ]]; then
      mapfile -t matches < <(printf '%s\n' "${matches[@]}" | sort -u)
    fi
    if [[ ${#matches[@]} -eq 1 ]]; then
      abs="${matches[0]}"
    elif [[ ${#matches[@]} -gt 1 ]]; then
      err "ambiguous folder name '$p': ${matches[*]}"; return 1
    else
      err "unknown workspace or folder: $p"; return 1
    fi
  fi
  [[ -d "$abs" ]] || { err "not a directory: $p"; return 1; }
  m="$(mount_for_host "$abs")"
  [[ -n "$m" ]] || { err "outside the mounted folders ($(joined_hosts)): $abs"; return 1; }
  printf '%s' "$abs"
}

container_path() {
  local m mh mc
  m="$(mount_for_host "$1")"
  [[ -n "$m" ]] || return 0
  IFS=$'\t' read -r mh mc <<<"$m"
  printf '%s%s' "$mc" "${1#"$mh"}"
}

# host path for a container path (inverse of container_path)
host_path_from_ctr() {
  local m mh mc
  m="$(mount_for_ctr "$1")"
  [[ -n "$m" ]] || return 0
  IFS=$'\t' read -r mh mc <<<"$m"
  printf '%s%s' "$mh" "${1#"$mc"}"
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

# --- container & herdr plumbing -----------------------------------------
# The container is a long-running compose service; herdr's server inside it
# owns every terminal. All herdr CLI calls go through `docker exec` (the
# CLI is inside the container; JSON is parsed there too, so the host needs
# nothing but docker).

compose() { (cd "$SERVICE_DIR" && docker compose "$@"); }

CTR=""

# the running sandbox container id (empty when the service is down)
find_ctr() {
  [[ -n "$CTR" ]] && return 0
  CTR="$(compose ps -q pi 2>/dev/null | head -1)"
  [[ -n "$CTR" ]]
}

require_stack() {
  find_ctr || die "the sandbox is not running — run ./run.sh to start it"
  docker exec "$CTR" herdr status server >/dev/null 2>&1 \
    || die "the herdr server is not answering in the container — see: docker compose logs"
}

# start (or resume) the container and wait until herdr accepts commands
ensure_stack() {
  ensure_image
  if ! find_ctr || ! docker exec "$CTR" herdr status server >/dev/null 2>&1; then
    echo "starting the sandbox container (herdr keeps everything running)..."
    compose up -d >/dev/null || die "cannot start the sandbox container"
    CTR=""
    local i
    for i in $(seq 1 60); do
      if find_ctr && docker exec "$CTR" herdr status server >/dev/null 2>&1; then
        return 0
      fi
      sleep 0.25
    done
    die "the herdr server did not come up — see: docker compose logs"
  fi
}

# run the herdr CLI inside the container
hcli() { docker exec "$CTR" herdr "$@"; }

# jq inside the container (the host needs no jq):  hcli ... | hjq -r '...'
hjq() { docker exec -i "$CTR" jq "$@"; }

# --- workspaces ----------------------------------------------------------
# Workspaces are found by id (w1...), by label (the folder's short path,
# e.g. "stack/services/pi", unless renamed in the TUI), or by the folder
# itself (label match, then root-pane cwd match).

ws_find_by_label() {
  hcli workspace list \
    | hjq -r --arg lbl "$1" \
      '[.result.workspaces[] | select(.label == $lbl)][0].workspace_id // empty'
}

ws_find_by_folder() {
  local lbl="$1" cpath="$2" id
  id="$(ws_find_by_label "$lbl")"
  [[ -n "$id" ]] && { printf '%s' "$id"; return 0; }
  # fall back to the workspace whose root pane lives in that folder
  hcli pane list \
    | hjq -r --arg cwd "$cpath" \
      '[.result.panes[] | select(.cwd == $cwd
          and .pane_id == (.workspace_id + ":p1"))][0].workspace_id // empty'
}

# resolve "<path|name|id>" to an existing workspace: prints "wid<tab>label"
ws_resolve() {
  local arg="${1:-}" id label
  if [[ "$arg" =~ ^w[0-9]+$ ]]; then
    label="$(hcli workspace list \
      | hjq -r --arg id "$arg" \
        '[.result.workspaces[] | select(.workspace_id == $id)][0].label // empty')"
    [[ -n "$label" ]] || { err "no workspace $arg"; return 1; }
    printf '%s\t%s\n' "$arg" "$label"
    return 0
  fi
  id="$(ws_find_by_label "$arg")"
  if [[ -n "$id" ]]; then
    printf '%s\t%s\n' "$id" "$arg"
    return 0
  fi
  local abs cpath lbl
  abs="$(host_path "$arg")" || return 1
  cpath="$(container_path "$abs")"
  lbl="$(short_path "$abs")"
  id="$(ws_find_by_folder "$lbl" "$cpath")"
  [[ -n "$id" ]] || { err "no workspace for $abs — open it first: ./run.sh $abs"; return 1; }
  printf '%s\t%s\n' "$id" "$lbl"
}

# the folder a workspace label belongs to (empty when unknown, e.g. after
# a rename in the TUI)
ws_host_path() {
  host_path_from_ctr "/workspace/$1"
}

# --- pi defaults ---------------------------------------------------------
# Same rule as container/pi-entrypoint.sh: apply PI_DEFAULT_PROVIDER/
# MODEL/THINKING (see docker-compose.yml) unless the caller picked a model
# or thinking level themselves. Read from the container env, so the
# compose files stay the single source of truth.
pi_default_flags() {
  local user_model=0 user_thinking=0 a
  for a in "$@"; do
    case "$a" in
      --model|--model=*|-m|--models|--models=*) user_model=1 ;;
      --thinking|--thinking=*) user_thinking=1 ;;
    esac
  done
  PI_FLAGS=()
  local prov model think
  prov="$(docker exec "$CTR" printenv PI_DEFAULT_PROVIDER 2>/dev/null || true)"
  model="$(docker exec "$CTR" printenv PI_DEFAULT_MODEL 2>/dev/null || true)"
  think="$(docker exec "$CTR" printenv PI_DEFAULT_THINKING 2>/dev/null || true)"
  if [[ $user_model -eq 0 ]]; then
    # a caller-provided model may belong to another provider, so the
    # default provider is only paired with the default model
    [[ -n "$prov" ]] && PI_FLAGS+=(--provider "$prov")
    [[ -n "$model" ]] && PI_FLAGS+=(--model "$model")
  fi
  if [[ $user_thinking -eq 0 && -n "$think" ]]; then
    PI_FLAGS+=(--thinking "$think")
  fi
}

# --- image ---------------------------------------------------------------
# The image is self-extending: pi-install records newly needed packages in
# the Dockerfile. A stamp label in the image lets us detect that the image
# no longer matches its sources and rebuild before starting anything.
image_stamp() {
  sha256sum "$SERVICE_DIR/container/Dockerfile" "$SERVICE_DIR/container/pi-install.sh" \
    "$SERVICE_DIR/container/pi-entrypoint.sh" "$SERVICE_DIR/container/install-herdr.sh" \
    "$SERVICE_DIR/container/pi-extensions.txt" "$SERVICE_DIR/container/pi-extensions-sync.sh" \
    "$SERVICE_DIR/container/pi-wrapper.sh" \
    2>/dev/null | sha256sum | cut -c1-16
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

# --- commands ------------------------------------------------------------

attach() {
  [[ -t 0 && -t 1 ]] || die "not a terminal — use -b to open a workspace without attaching"
  echo "herdr TUI — detach with ctrl+b q (panes and agents keep running)"
  exec docker exec -it \
    -e TERM="${TERM:-xterm-256color}" -e COLORTERM="${COLORTERM:-}" \
    "$CTR" herdr
}

# focus an existing workspace and (optionally) attach the TUI to it
jump_to() {
  local wid="$1" label="$2" bg="$3"
  hcli workspace focus "$wid" >/dev/null || true
  if [[ $bg -eq 1 ]]; then
    echo "opened $label — attach with: ./run.sh $label"
  else
    attach
  fi
}

cmd_open() {
  local bg=0 path
  while [[ "${1:-}" == -b || "${1:-}" == --background ]]; do
    bg=1
    shift
  done
  if [[ $# -gt 0 && "$1" != -* ]]; then
    path="$1"
    shift
  else
    # no folder given: the current one ("." is accepted explicitly)
    path="."
  fi

  ensure_stack

  local abs="" out wid label
  if [[ "$path" == "." ]] && ! abs="$(host_path . 2>/dev/null)"; then
    # from outside the mounted folders with no path given: just attach
    # wherever the TUI was left (its focused workspace)
    if [[ $# -gt 0 ]]; then
      die "the current folder is not mounted (mounted: $(joined_hosts))"
    fi
    if [[ $bg -eq 1 ]]; then
      echo "the current folder is not mounted — attaching is the only option (drop -b)"
      exit 1
    fi
    attach
  fi
  if [[ -z "$abs" ]]; then
    if ! abs="$(host_path "$path" 2>/dev/null)"; then
      # not a folder — a workspace id (w3) or name, then
      out="$(ws_resolve "$path")" || exit 1
      IFS=$'\t' read -r wid label <<<"$out"
      [[ $# -gt 0 ]] && echo "note: workspace exists, pi args ignored" >&2
      jump_to "$wid" "$label" "$bg"
      return
    fi
  fi

  local cdir lbl pid
  cdir="$(container_path "$abs")"
  lbl="$(short_path "$abs")"
  wid="$(ws_find_by_folder "$lbl" "$cdir")"

  if [[ -n "$wid" ]]; then
    [[ $# -gt 0 ]] && echo "note: workspace exists, pi args ignored" >&2
  else
    echo "opening workspace $lbl"
    out="$(hcli workspace create --cwd "$cdir" --label "$lbl" --focus)" \
      || die "could not create a herdr workspace for $abs"
    wid="$(printf '%s' "$out" | hjq -r '.result.workspace.workspace_id')"
    pid="$(printf '%s' "$out" | hjq -r '.result.root_pane.pane_id')"
    # first open of the folder starts pi in its workspace — as before, with
    # the PI_DEFAULT_* defaults unless the caller chose a model
    pi_default_flags "$@"
    local name
    name="pi-$(slugify "$(basename "$abs")")"
    name="${name:0:24}-$(hash4 "$abs")"
    if ! hcli agent start "$name" --kind pi --pane "$pid" \
        --timeout 60000 -- ${PI_FLAGS[@]+"${PI_FLAGS[@]}"} "$@" >/dev/null; then
      err "note: pi did not start as a recognized agent — the workspace is open, run pi in it yourself"
    fi
  fi

  jump_to "$wid" "$lbl" "$bg"
}

cmd_ls() {
  require_stack
  local watch=0
  if [[ "${1:-}" == "-w" || "${1:-}" == "--watch" ]]; then watch=1; fi
  while true; do
    if [[ $watch -eq 1 ]]; then
      clear
      echo "pi sandbox — $(date '+%Y-%m-%d %H:%M:%S') — ctrl+c to stop watching"
      echo
    fi
    printf '%-8s %-28s %-9s %-9s %s\n' WORKSPACE FOLDER STATE AGENT LAST
    hcli workspace list | hjq -r \
      '.result.workspaces[] | [.workspace_id, .label,
        (if .focused then "focused" else "-" end),
        (.agent_status // "-")] | @tsv' \
    | while IFS=$'\t' read -r wid lbl state st; do
        local last
        last="$(hcli pane read "$wid:p1" --source recent-unwrapped --lines 40 2>/dev/null \
          | sed 's/[[:space:]]*$//' | awk 'NF { l = $0 } END { print l }' | cut -c1-44)"
        printf '%-8s %-28s %-9s %-9s %s\n' "$wid" "$lbl" "$state" "$st" "${last:-}"
      done
    echo
    printf '%-8s %-12s %-9s %-8s %s\n' AGENT KIND STATE WORKSPACE PANE
    hcli agent list | hjq -r \
      '.result.agents[] | [.name, .agent, .agent_status, .workspace_id, .pane_id] | @tsv' \
    | while IFS=$'\t' read -r name kind st wid pane; do
        printf '%-8s %-12s %-9s %-8s %s\n' "$name" "$kind" "$st" "$wid" "$pane"
      done
    if [[ $watch -eq 0 ]]; then break; fi
    sleep 2
  done
}

cmd_log() {
  require_stack
  local out wid label pid
  out="$(ws_resolve "${1:-.}")" || exit 1
  IFS=$'\t' read -r wid label <<<"$out"
  # the workspace's focused pane, else its first one
  pid="$(hcli pane list --workspace "$wid" | hjq -r \
    '([.result.panes[] | select(.focused)][0] // .result.panes[0]).pane_id // empty')"
  [[ -n "$pid" ]] || die "no pane in workspace $label"
  hcli pane read "$pid" --source recent-unwrapped --lines 300
}

cmd_shell() {
  ensure_stack
  local arg="${1:-}" out wid label abs cdir
  if [[ $# -gt 0 && "$1" != -* ]]; then
    shift
  else
    arg="."
  fi
  if out="$(ws_resolve "$arg" 2>/dev/null)"; then
    IFS=$'\t' read -r wid label <<<"$out"
    abs="$(ws_host_path "$label")"
    [[ -n "$abs" ]] || die "no folder recorded for workspace $label"
  else
    abs="$(host_path "$arg")" || exit 1
  fi
  cdir="$(container_path "$abs")"
  local tflags="-i"
  [[ -t 0 && -t 1 ]] && tflags="-it"
  # shellcheck disable=SC2086
  if [[ $# -gt 0 ]]; then
    local cmd
    printf -v cmd '%q ' "$@"
    exec docker exec $tflags -w "$cdir" "$CTR" bash -c "$cmd"
  fi
  exec docker exec $tflags -w "$cdir" "$CTR" bash
}

kill_ws() {
  local out wid label
  out="$(ws_resolve "$1")" || return 1
  IFS=$'\t' read -r wid label <<<"$out"
  hcli workspace close "$wid" >/dev/null || die "could not close $label"
  echo "closed $label"
}

cmd_kill() {
  require_stack
  if [[ "${1:-}" == "--all" ]]; then
    local ids id
    ids="$(hcli workspace list | hjq -r '.result.workspaces[].workspace_id')"
    for id in $ids; do
      hcli workspace close "$id" >/dev/null 2>&1 || true
    done
    echo "closed all workspaces (the sandbox keeps running)"
  else
    kill_ws "${1:-.}" || exit 1
  fi
}

cmd_down() {
  echo "stopping the sandbox — herdr restores the layout and pi sessions on the next start"
  compose down
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

# Same for herdr: pinned via ARG HERDR_VERSION, baked into the next build.
# (`herdr update` inside the container only changes the running container.)
cmd_upgrade_herdr() {
  local ver="${1:-}" old
  if [[ -z "$ver" ]]; then
    if ! ver="$(curl -fsSL --max-time 20 https://herdr.dev/latest.json \
        | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"; then
      die "could not query herdr.dev for the latest version"
    fi
  fi
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+-][A-Za-z0-9.+-]*)?$ ]] \
    || die "invalid version: $ver"
  old="$(sed -n 's/^ARG HERDR_VERSION=//p' "$SERVICE_DIR/container/Dockerfile")"
  if [[ "$old" == "$ver" ]]; then
    echo "herdr already pinned to $ver in Dockerfile"
  else
    sed -i "s/^ARG HERDR_VERSION=.*/ARG HERDR_VERSION=${ver}/" "$SERVICE_DIR/container/Dockerfile"
    echo "herdr pinned to $ver in Dockerfile (was ${old:-unset})"
  fi
  ensure_image
  echo "done — new sessions run herdr $ver"
}

case "${1:-}" in
  ""|open) shift 2>/dev/null || true; cmd_open "$@" ;;
  ls|list|ps) shift; cmd_ls "$@" ;;
  log|peek) shift; cmd_log "$@" ;;
  shell|sh|bash) shift; cmd_shell "$@" ;;
  kill|stop|rm) shift; cmd_kill "$@" ;;
  down) shift; cmd_down "$@" ;;
  upgrade|up|update) shift; cmd_upgrade "$@" ;;
  upgrade-herdr) shift; cmd_upgrade_herdr "$@" ;;
  help|-h|--help) usage ;;
  *) cmd_open "$@" ;;
esac
