#!/usr/bin/env bash
# pi-worktree — one isolated git worktree per parallel agent.
#
# When more than one agent works in the same repo at the same time, every
# agent gets its own worktree on its own feature branch (see
# container/AGENTS.md "Parallel agents"). This helper standardizes that
# lifecycle so worktrees never collide and cleanup is safe:
#
#   pi-worktree create <slug> [--base <branch>]   new worktree + agent/<slug> branch
#   pi-worktree list                              all worktrees with branch + dirty state
#   pi-worktree sync                              fetch origin + ahead/behind per worktree (read-only)
#   pi-worktree remove <id> [--delete-branch] [--force]
#                                                 remove a worktree, keep the branch by default
#   pi-worktree finish <id> [--no-push] [--keep]  push branch + remove worktree (end of task)
#   pi-worktree prune                             drop stale worktree metadata
#
# <id> is a slug, a worktree path, or a branch name — whatever is handy.
#
# Safety model: removing a worktree never loses COMMITTED work (it lives on
# the branch); only uncommitted work is at risk. So `remove`/`finish` refuse
# a dirty worktree unless --force, `remove` keeps the branch unless
# --delete-branch, and only `finish` (after push) is meant to run
# unattended at the end of a task.
#
# Worktrees live at <repo>/.worktrees/<slug> (nested, so they stay inside
# the sandbox's /workspace mounts — a sibling directory could fall outside
# a mount and never reach the host). Only used inside the container.
set -euo pipefail

err() { printf 'pi-worktree: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

usage() {
  sed -n '2,/^set -euo pipefail$/p' "$0" | sed 's/^# \?//'
}

# slugify: lowercase, dashes, max 40 chars
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-40
}

# repo root for the current directory (or --repo)
repo_root() {
  git rev-parse --show-toplevel 2>/dev/null \
    || die "not inside a git repo — worktrees need one (non-git folders: copy the folder per agent instead)"
}

# List worktrees as "path<TAB>branch-or-empty" lines, main worktree first.
# Prints also MAIN=<main-path> on the first line? No — keep it simple:
# callers parse; main path helper below.
worktree_table() {
  local root="$1" path="" branch="" line
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        [[ -n "$path" ]] && printf '%s\t%s\n' "$path" "$branch"
        path="${line#worktree }"; branch="" ;;
      branch\ refs/heads/*)
        branch="${line#branch refs/heads/}" ;;
      detached|bare)
        branch="$line" ;;
      "") ;; 
    esac
  done < <(git -C "$root" worktree list --porcelain)
  [[ -n "$path" ]] && printf '%s\t%s\n' "$path" "$branch"
}

main_worktree() {
  git -C "$1" worktree list --porcelain \
    | awk '/^worktree / { print substr($0, 10); exit }'
}

# Resolve <id> to a worktree path. Prints the path.
resolve_worktree() {
  local root="$1" id="$2" p b found=""
  # 1. exact directory match (follows symlinks loosely via string compare)
  while IFS=$'\t' read -r p b; do
    if [[ "$id" == "$p" || "$id" == "$(basename "$p")" && "$p" == "$root/.worktrees/"* ]]; then
      found="$p"; break
    fi
  done < <(worktree_table "$root")
  # 2. slug -> default location
  if [[ -z "$found" && -d "$root/.worktrees/$id" ]]; then
    found="$root/.worktrees/$id"
  fi
  # 3. branch name (bare or agent/-prefixed)
  if [[ -z "$found" ]]; then
    while IFS=$'\t' read -r p b; do
      if [[ "$id" == "$b" || "agent/$id" == "$b" ]]; then
        found="$p"; break
      fi
    done < <(worktree_table "$root")
  fi
  [[ -n "$found" ]] || die "no worktree '$id' — see: pi-worktree list"
  printf '%s' "$found"
}

branch_of() {
  local root="$1" path="$2" p b
  while IFS=$'\t' read -r p b; do
    if [[ "$p" == "$path" ]]; then printf '%s' "$b"; return 0; fi
  done < <(worktree_table "$root")
}

ensure_not_main() {
  local root="$1" path="$2"
  [[ "$path" != "$(main_worktree "$root")" ]] \
    || die "refusing to touch the main checkout ($path) — work on agent worktrees only"
}

cmd_create() {
  local slug="" base="" root branch path n suffix raw
  [[ $# -gt 0 ]] || die "usage: pi-worktree create <slug> [--base <branch>]"
  raw="$1"; slug="$(slugify "$1")"; shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base) base="${2:-}"; shift 2 ;;
      --base=*) base="${1#--base=}"; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  [[ "$slug" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
    || die "bad slug '$raw' — use short lowercase words with dashes"
  root="$(repo_root)"
  if [[ -z "$base" ]]; then
    base="$(git -C "$root" branch --show-current 2>/dev/null || true)"
    [[ -n "$base" ]] || base="HEAD"
  fi
  git -C "$root" rev-parse --verify --quiet "$base^{commit}" >/dev/null \
    || die "base '$base' does not exist — pass --base <branch>"
  # uniquify slug/branch/path together (plain first, then -2, -3, ...)
  n=1
  while :; do
    suffix=""; [[ $n -gt 1 ]] && suffix="-$n"
    branch="agent/${slug}${suffix}"
    path="$root/.worktrees/${slug}${suffix}"
    if git -C "$root" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null \
       || [[ -e "$path" ]]; then
      n=$((n + 1))
    else
      break
    fi
  done
  # keep nested worktrees out of `git status` in the main checkout
  local exclude
  exclude="$(git -C "$root" rev-parse --git-common-dir)/info/exclude"
  if ! grep -qxF '.worktrees/' "$exclude" 2>/dev/null; then
    mkdir -p "$(dirname "$exclude")"
    printf '.worktrees/\n' >> "$exclude"
  fi
  git -C "$root" worktree add -b "$branch" "$path" "$base" \
    || die "could not create the worktree"
  printf 'pi-worktree: created %s on branch %s (base %s)\n' "$path" "$branch" "$base"
  printf 'branch=%s\npath=%s\nbase=%s\n' "$branch" "$path" "$base"
  cat >&2 <<EOF
pi-worktree: next steps inside the worktree:
  cd $path   # the agent stays here for the whole task
  <install deps: node_modules/.env are NOT copied — e.g. npm ci>
  <copy needed ignored files from $root, never commit secrets>
EOF
}

cmd_list() {
  local root p b dirty head
  root="$(repo_root)"
  printf '%-48s %-28s %-7s %s\n' WORKTREE BRANCH STATE HEAD
  while IFS=$'\t' read -r p b; do
    [[ -z "$p" ]] && continue
    head="$(git -C "$p" rev-parse --short HEAD 2>/dev/null || echo '?')"
    if [[ -n "$(git -C "$p" status --porcelain=v1 2>/dev/null)" ]]; then
      dirty="dirty"
    else
      dirty="clean"
    fi
    [[ "$p" == "$(main_worktree "$root")" ]] && dirty="$dirty,main"
    printf '%-48s %-28s %-7s %s\n' "$p" "${b:-?}" "$dirty" "$head"
  done < <(worktree_table "$root")
}

# internal removal; assumes root+path resolved. $3 = delete-branch flag,
# $4 = force flag.
do_remove() {
  local root="$1" path="$2" del_branch="$3" force="$4"
  ensure_not_main "$root" "$path"
  local branch
  branch="$(branch_of "$root" "$path")"
  local args=()
  [[ "$force" == 1 ]] && args+=(--force)
  if ! git -C "$root" worktree remove "${args[@]+${args[@]}}" "$path" 2>/tmp/pi-worktree-err; then
    if grep -qi 'untracked\|modified\|dirty' /tmp/pi-worktree-err 2>/dev/null; then
      err "worktree is dirty — commit or stash inside $path first, or retry with --force (loses uncommitted work)"
    fi
    cat /tmp/pi-worktree-err >&2 || true
    rm -f /tmp/pi-worktree-err
    return 1
  fi
  rm -f /tmp/pi-worktree-err
  # warn when the branch was never pushed (commits are still safe locally)
  if [[ -n "$branch" && "$branch" != detached && "$branch" != bare ]]; then
    if ! git -C "$root" rev-parse --verify --quiet "$branch@{u}" >/dev/null 2>&1; then
      printf 'pi-worktree: note: branch %s has no upstream — kept locally, push it before it matters\n' "$branch" >&2
    fi
    if [[ "$del_branch" == 1 ]]; then
      if [[ "$force" == 1 ]]; then
        git -C "$root" branch -D "$branch"
      else
        git -C "$root" branch -d "$branch" \
          || die "branch $branch is not merged — merge it first, or retry with --force"
      fi
      printf 'pi-worktree: deleted branch %s\n' "$branch" >&2
    else
      printf 'pi-worktree: removed %s (branch %s kept)\n' "$path" "$branch" >&2
    fi
  else
    printf 'pi-worktree: removed %s\n' "$path" >&2
  fi
  git -C "$root" worktree prune
}

cmd_remove() {
  local id="" del_branch=0 force=0 root path
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --delete-branch) del_branch=1; shift ;;
      --force) force=1; shift ;;
      -*) die "unknown flag: $1" ;;
      *) [[ -z "$id" ]] || die "one worktree at a time"; id="$1"; shift ;;
    esac
  done
  [[ -n "$id" ]] || die "usage: pi-worktree remove <slug|path|branch> [--delete-branch] [--force]"
  root="$(repo_root)"
  path="$(resolve_worktree "$root" "$id")"
  do_remove "$root" "$path" "$del_branch" "$force"
}

cmd_finish() {
  local id="" push=1 keep=0 root path branch
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-push) push=0; shift ;;
      --keep) keep=1; shift ;;
      -*) die "unknown flag: $1" ;;
      *) [[ -z "$id" ]] || die "one worktree at a time"; id="$1"; shift ;;
    esac
  done
  [[ -n "$id" ]] || die "usage: pi-worktree finish <slug|path|branch> [--no-push] [--keep]"
  root="$(repo_root)"
  path="$(resolve_worktree "$root" "$id")"
  ensure_not_main "$root" "$path"
  branch="$(branch_of "$root" "$path")"
  case "$branch" in
    ""|detached|bare) die "worktree has no branch — nothing to finish" ;;
    main|master) die "refusing to finish on $branch — agent work lives on agent/* branches" ;;
  esac
  [[ -z "$(git -C "$path" ls-files -u)" ]] \
    || die "unmerged paths in $path — resolve conflicts first"
  [[ -z "$(git -C "$path" status --porcelain=v1)" ]] \
    || die "worktree is dirty — commit inside $path first (then re-run finish)"
  if [[ "$push" == 1 ]]; then
    if git -C "$path" remote get-url origin >/dev/null 2>&1; then
      git -C "$path" push -u origin "$branch" \
        || die "push failed — fix and re-run finish"
    else
      printf 'pi-worktree: note: no origin remote — skipping push, branch kept locally\n' >&2
    fi
  fi
  if [[ "$keep" == 1 ]]; then
    printf 'pi-worktree: done — branch %s pushed, worktree %s kept (--keep)\n' "$branch" "$path"
  else
    do_remove "$root" "$path" 0 0
    printf 'pi-worktree: done — branch %s ready to review\n' "$branch"
    printf 'merge with: git switch <main> && git merge --no-ff %s && git branch -d %s\n' "$branch" "$branch"
  fi
}

cmd_prune() {
  local root
  root="$(repo_root)"
  git -C "$root" worktree prune
  git -C "$root" worktree repair 2>/dev/null || true
  cmd_list
}

# read-only divergence overview: fetch origin, then show every worktree's
# branch ahead/behind its upstream (or the same-named origin branch).
# Supervisors run this before merging to see which lanes are stale.
cmd_sync() {
  local root p b head dirty upstream ab behind ahead counts
  root="$(repo_root)"
  if git -C "$root" remote get-url origin >/dev/null 2>&1; then
    git -C "$root" fetch origin --quiet 2>/dev/null \
      || printf 'pi-worktree: note: fetch origin failed (offline?) — showing last-known refs\n' >&2
  else
    printf 'pi-worktree: note: no origin remote — comparing against local refs only\n' >&2
  fi
  printf '%-44s %-24s %-11s %-11s %s\n' WORKTREE BRANCH VS-UPSTREAM STATE HEAD
  while IFS=$'\t' read -r p b; do
    [[ -z "$p" ]] && continue
    head="$(git -C "$p" rev-parse --short HEAD 2>/dev/null || echo '?')"
    dirty="clean"
    [[ -n "$(git -C "$p" status --porcelain=v1 2>/dev/null)" ]] && dirty="dirty"
    [[ "$p" == "$(main_worktree "$root")" ]] && dirty="$dirty,main"
    upstream="$(git -C "$p" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
    if [[ -z "$upstream" && -n "$b" && "$b" != detached && "$b" != bare ]] \
       && git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null 2>&1; then
      upstream="origin/$b"
    fi
    ab="-"
    if [[ -n "$upstream" ]]; then
      counts="$(git -C "$p" rev-list --left-right --count "$upstream...HEAD" 2>/dev/null || true)"
      if [[ -n "$counts" ]]; then
        IFS=$'\t' read -r behind ahead <<<"$counts"
        ab="+$ahead/-$behind"
      fi
    fi
    printf '%-44s %-24s %-11s %-11s %s\n' "$p" "${b:-?}" "$ab" "$dirty" "$head"
  done < <(worktree_table "$root")
}

case "${1:-}" in
  create) shift; cmd_create "$@" ;;
  list|ls) shift; cmd_list "$@" ;;
  sync) shift; cmd_sync "$@" ;;
  remove|rm) shift; cmd_remove "$@" ;;
  finish|done) shift; cmd_finish "$@" ;;
  prune) shift; cmd_prune "$@" ;;
  -h|--help|help|"") usage ;;
  *) die "unknown command '$1' — see: pi-worktree --help" ;;
esac
