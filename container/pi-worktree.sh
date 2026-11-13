#!/usr/bin/env bash
# pi-worktree — one isolated git worktree per parallel agent.
#
# When more than one agent works in the same repo at the same time, every
# agent gets its own worktree on its own feature branch (see WORKTREES.md,
# and container/AGENTS.md "Parallel agents" for the agent rules).
# This helper standardizes that lifecycle so worktrees never collide
# and cleanup is safe:
#
#   pi-worktree create <slug> [--base <branch>]   new worktree + agent/<slug> branch
#   pi-worktree list                              all worktrees with branch + dirty state
#   pi-worktree sync                              fetch origin + ahead/behind per worktree (read-only)
#   pi-worktree remove <id> [--delete-branch] [--force]
#                                                 remove a worktree, keep the branch by default
#   pi-worktree finish <id> [--no-push] [--keep]  push branch + remove worktree (end of task)
#   pi-worktree propose <id> [--draft]            push + open a PR with gh + remove worktree (agent end-of-task)
#   pi-worktree land <id> [--delete-remote]       merge a finished branch into main + clean up
#   pi-worktree tidy                              drop merged worktrees/branches (safe cleanup)
#   pi-worktree prune                             drop stale worktree metadata
#
# <id> is a slug, a worktree path, or a branch name — whatever is handy.
#
# Full human guide: WORKTREES.md in the service repo (mental model, who
# merges when, how parallel tasks share one workspace).
#
# Safety model: removing a worktree never loses COMMITTED work (it lives on
# the branch); only uncommitted work is at risk. So `remove`/`finish` refuse
# a dirty worktree unless --force, `remove` keeps the branch unless
# --delete-branch, `land` only merges committed work through the main
# checkout, and only `finish`/`propose` (after push) are meant to run
# unattended at the end of a task. `propose` additionally opens a PR, so
# the work is reviewable on GitHub even after its worktree is gone.
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
    printf 'land it with: pi-worktree land %s   (merges into main, deletes the branch)\n' "$branch"
    printf 'or open a PR first: pi-worktree propose %s\n' "$branch"
  fi
}

# Push the branch, open a PR with gh, and remove the worktree.
# This is the agent's end-of-task command: the work becomes reviewable on
# GitHub (nothing gets lost — the PR holds the commits) and the checkout is
# freed. Removing the worktree is safe: the local branch, the remote branch
# and the PR all keep the commits. Run from anywhere in the repo. Merging
# the PR is the supervisor's job (Merge button, or `pi-worktree land`);
# after the merge, `tidy` drops the local leftovers.
cmd_propose() {
  local id="" draft=0 root path="" branch="" def="" workdir="" pr_url="" args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --draft) draft=1; shift ;;
      -*) die "unknown flag: $1" ;;
      *) [[ -z "$id" ]] || die "one branch at a time"; id="$1"; shift ;;
    esac
  done
  [[ -n "$id" ]] || die "usage: pi-worktree propose <slug|path|branch> [--draft]"
  command -v gh >/dev/null 2>&1 \
    || die "gh not found — cannot open a PR (use pi-worktree finish instead)"
  gh auth status >/dev/null 2>&1 \
    || die "gh is not logged in — run: gh auth login (or use pi-worktree finish instead)"
  root="$(repo_root)"
  git -C "$root" remote get-url origin >/dev/null 2>&1 \
    || die "no origin remote — cannot open a PR (use pi-worktree finish --no-push instead)"
  # Worktree may already be gone (finished earlier) — the branch alone is
  # enough to propose from.
  # NOTE: the `if` must wrap the substitution (not `|| true` inside it):
  # a dying helper inside $(...) would take the whole shell down under
  # `set -e`, even with `|| true` in the subshell.
  if path="$(resolve_worktree "$root" "$id" 2>/dev/null)"; then
    branch="$(branch_of "$root" "$path")"
  else
    path=""
  fi
  if [[ -z "${branch:-}" || "$branch" == detached || "$branch" == bare ]]; then
    branch=""
    if git -C "$root" show-ref --verify --quiet "refs/heads/$id" 2>/dev/null; then
      branch="$id"
    elif git -C "$root" show-ref --verify --quiet "refs/heads/agent/$id" 2>/dev/null; then
      branch="agent/$id"
    else
      die "no worktree or branch '$id' — see: pi-worktree list"
    fi
    if ! path="$(resolve_worktree "$root" "$branch" 2>/dev/null)"; then
      path=""
    fi
  fi
  case "$branch" in
    main|master) die "refusing to propose $branch — agent work lives on agent/* branches" ;;
    ""|detached|bare) die "worktree has no branch — nothing to propose" ;;
  esac
  if [[ -n "$path" ]]; then
    ensure_not_main "$root" "$path"
    [[ -z "$(git -C "$path" ls-files -u)" ]] \
      || die "unmerged paths in $path — resolve conflicts first"
    [[ -z "$(git -C "$path" status --porcelain=v1)" ]] \
      || die "worktree is dirty — commit inside $path first (then re-run propose)"
    workdir="$path"
  else
    workdir="$root"
  fi
  def="$(default_branch "$root")"
  [[ -n "$def" ]] || die "cannot determine the default branch (no main/master?)"
  # Push first, so the PR has content (re-running updates an open PR).
  if [[ -n "$path" ]]; then
    git -C "$path" push -u origin "$branch" \
      || die "push failed — fix and re-run propose"
  else
    git -C "$root" push origin "$branch" \
      || die "push failed — fix and re-run propose"
  fi
  # gh resolves the repo from the cwd — run it inside the worktree (or root).
  if pr_url="$(cd "$workdir" && gh pr view "$branch" --json url --jq .url 2>/dev/null)" \
     && [[ -n "$pr_url" ]]; then
    printf 'pi-worktree: PR already open: %s\n' "$pr_url" >&2
  else
    args=(pr create --base "$def" --head "$branch" --fill)
    [[ "$draft" == 1 ]] && args+=(--draft)
    if ! pr_url="$(cd "$workdir" && gh "${args[@]}" 2>/tmp/pi-pr-err)"; then
      cat /tmp/pi-pr-err >&2 || true
      rm -f /tmp/pi-pr-err
      die "gh pr create failed (branch is pushed) — resolve and re-run propose"
    fi
    rm -f /tmp/pi-pr-err
    printf 'pi-worktree: opened %s\n' "$pr_url" >&2
  fi
  if [[ -n "$path" ]]; then
    do_remove "$root" "$path" 0 0
  fi
  printf 'pi-worktree: proposed %s -> %s\n' "$branch" "$pr_url"
  printf 'pi-worktree: next: review the PR, merge it, then run: git pull && pi-worktree tidy\n'
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

# default integration branch: origin/HEAD if set, else local main/master,
# else whatever the main worktree is on. Centralizes the "<main>" choice
# so finish/land/tidy agree (previously finish printed a literal <main>).
default_branch() {
  local root="$1" ref sym
  if git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/HEAD" >/dev/null 2>&1; then
    sym="$(git -C "$root" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)"
    ref="${sym#refs/remotes/origin/}"
    if [[ -n "$ref" && "$ref" != "$sym" ]]; then printf '%s' "$ref"; return 0; fi
  fi
  if git -C "$root" show-ref --verify --quiet "refs/heads/main" 2>/dev/null; then
    printf 'main'; return 0
  fi
  if git -C "$root" show-ref --verify --quiet "refs/heads/master" 2>/dev/null; then
    printf 'master'; return 0
  fi
  git -C "$(main_worktree "$root")" branch --show-current 2>/dev/null || true
}

# Merge a finished agent branch into the default branch and clean up.
# Runs in the MAIN checkout (never inside a worker worktree): switches the
# main worktree to <default>, fast-forwards it when possible, merges with
# --no-ff, deletes the local branch, removes the worktree if it still
# exists, and prunes. Uncommitted work anywhere blocks the merge.
cmd_land() {
  local id="" del_remote=0 root path="" branch="" main_wt="" def=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --delete-remote|-r) del_remote=1; shift ;;
      -*) die "unknown flag: $1" ;;
      *) [[ -z "$id" ]] || die "one branch at a time"; id="$1"; shift ;;
    esac
  done
  [[ -n "$id" ]] || die "usage: pi-worktree land <slug|path|branch> [--delete-remote]"
  root="$(repo_root)"
  # Worktree may already be gone (finished earlier) — resolve either way.
  # NOTE: the `if` must wrap the substitution (not `|| true` inside it):
  # a dying helper inside $(...) would take the whole shell down under
  # `set -e`, even with `|| true` in the subshell.
  if path="$(resolve_worktree "$root" "$id" 2>/dev/null)"; then
    branch="$(branch_of "$root" "$path")"
  else
    path=""
  fi
  if [[ -z "${branch:-}" || "$branch" == detached || "$branch" == bare || -z "$branch" ]]; then
    branch=""
    if git -C "$root" show-ref --verify --quiet "refs/heads/$id" 2>/dev/null; then
      branch="$id"
    elif git -C "$root" show-ref --verify --quiet "refs/heads/agent/$id" 2>/dev/null; then
      branch="agent/$id"
    else
      die "no worktree or branch '$id' — see: pi-worktree list"
    fi
    if ! path="$(resolve_worktree "$root" "$branch" 2>/dev/null)"; then
      path=""
    fi
  fi
  case "$branch" in
    main|master) die "refusing to land $branch onto itself — land agent/* branches only" ;;
    ""|detached|bare) die "worktree has no branch — nothing to land" ;;
  esac
  git -C "$root" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null \
    || die "branch $branch does not exist locally"
  main_wt="$(main_worktree "$root")"
  def="$(default_branch "$root")"
  [[ -n "$def" ]] || die "cannot determine the default branch (no main/master?)"
  [[ -z "$(git -C "$main_wt" status --porcelain=v1 2>/dev/null)" ]] \
    || die "main checkout $main_wt is dirty — commit/stash there first"
  if [[ -n "$path" && "$path" != "$main_wt" ]]; then
    [[ -z "$(git -C "$path" status --porcelain=v1 2>/dev/null)" ]] \
      || die "worktree $path is dirty — commit inside it first (then re-run land)"
    [[ -z "$(git -C "$path" ls-files -u)" ]] \
      || die "unmerged paths in $path — resolve conflicts first"
  fi
  git -C "$root" fetch origin --quiet 2>/dev/null || true
  git -C "$main_wt" switch "$def" --quiet 2>/dev/null \
    || git -C "$main_wt" checkout "$def" --quiet 2>/dev/null \
    || die "cannot switch the main checkout to $def"
  # Fast-forward main when it only trails its upstream — keeps the merge
  # base fresh without ever merging into main from here.
  if git -C "$main_wt" rev-parse --verify --quiet "@{u}" >/dev/null 2>&1; then
    git -C "$main_wt" pull --ff-only --quiet 2>/dev/null \
      || printf 'pi-worktree: note: could not fast-forward %s (diverged?) — merging anyway\n' "$def" >&2
  fi
  git -C "$main_wt" merge --no-ff -m "Merge branch '$branch'" "$branch" \
    || die "merge conflicts — resolve them in $main_wt, commit, then clean up with: pi-worktree remove $branch --delete-branch"
  if [[ -n "$path" && "$path" != "$main_wt" ]]; then
    do_remove "$root" "$path" 1 0
  else
    git -C "$root" branch -d "$branch" \
      || die "merged but could not delete branch $branch — remove it manually"
  fi
  if [[ "$del_remote" == 1 ]]; then
    if git -C "$root" remote get-url origin >/dev/null 2>&1; then
      git -C "$root" push origin --delete "$branch" 2>/dev/null \
        || printf 'pi-worktree: note: merged locally but remote delete failed\n' >&2
    fi
  fi
  git -C "$root" worktree prune
  printf 'pi-worktree: landed %s into %s\n' "$branch" "$def"
}

# Merged into the default branch — locally, or into its origin copy (a PR
# merged on GitHub lands there before you pull). The ancestor checks are
# the safety case for the -D deletes in tidy: every erased commit stays
# reachable from the default branch.
is_merged() {
  local root="$1" b="$2" def="$3"
  git -C "$root" merge-base --is-ancestor "$b" "$def" 2>/dev/null && return 0
  git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$def" >/dev/null 2>&1 \
    && git -C "$root" merge-base --is-ancestor "$b" "origin/$def" 2>/dev/null
}

# Safe janitor: prune stale metadata, fetch --prune, drop worktrees whose
# branch is already merged (e.g. after its PR was merged), and delete local
# agent/* branches merged into the default branch. Never deletes unmerged
# work, never touches dirty worktrees, never deletes remotes. Run whenever
# `list` looks cluttered — typically right after pulling merged PRs.
cmd_tidy() {
  local root main_wt def b p merged=0 kept=0 freed=0 behind
  root="$(repo_root)"
  git -C "$root" worktree prune
  git -C "$root" worktree repair 2>/dev/null || true
  git -C "$root" fetch origin --prune --quiet 2>/dev/null || true
  main_wt="$(main_worktree "$root")"
  def="$(default_branch "$root")"
  [[ -n "$def" ]] || die "cannot determine the default branch (no main/master?)"
  # 1. Worktrees on merged branches are dead weight (the PR is merged, the
  #    commits are safe) — remove the checkout when clean. Branch deletion
  #    happens in step 2. A merged PR does NOT do this for you: GitHub
  #    cannot reach your machine; tidy is the step that reaps it locally.
  while IFS=$'\t' read -r p b; do
    [[ -n "$p" && -n "$b" ]] || continue
    [[ "$p" == "$main_wt" ]] && continue
    case "$b" in agent/*) ;; *) continue ;; esac
    if is_merged "$root" "$b" "$def"; then
      if [[ -n "$(git -C "$p" status --porcelain=v1 2>/dev/null)" ]]; then
        printf 'pi-worktree: tidy: keeping worktree %s — dirty despite merged branch (commit/stash, then re-run)\n' "$p" >&2
        kept=$((kept + 1))
      elif git -C "$root" worktree remove "$p" 2>/dev/null; then
        printf 'pi-worktree: tidy: removed merged worktree %s\n' "$p" >&2
        freed=$((freed + 1))
      else
        printf 'pi-worktree: tidy: keeping worktree %s (remove failed)\n' "$p" >&2
        kept=$((kept + 1))
      fi
    fi
  done < <(worktree_table "$root")
  git -C "$root" worktree prune
  # 2. Local agent/* branches merged into the default branch: safe to
  #    delete (is_merged above is the guarantee, so -D is exact here).
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    case "$b" in agent/*) ;; *) continue ;; esac
    if is_merged "$root" "$b" "$def"; then
      if worktree_table "$root" | cut -f2 | grep -qx "$b"; then
        printf 'pi-worktree: tidy: keeping %s (still checked out)\n' "$b" >&2
        kept=$((kept + 1))
      elif git -C "$root" branch -D "$b" >/dev/null 2>&1; then
        printf 'pi-worktree: tidy: deleted merged branch %s\n' "$b" >&2
        merged=$((merged + 1))
      else
        printf 'pi-worktree: tidy: keeping %s (delete failed)\n' "$b" >&2
        kept=$((kept + 1))
      fi
    else
      kept=$((kept + 1))
    fi
  done < <(git -C "$root" for-each-ref --format='%(refname:short)' refs/heads/agent/)
  git -C "$root" worktree prune
  # 3. Merged-on-GitHub lanes only become visible to steps 1-2 after a pull.
  if git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$def" >/dev/null 2>&1; then
    behind="$(git -C "$root" rev-list --count "$def..origin/$def" 2>/dev/null || echo 0)"
    if [[ "$behind" != "0" ]]; then
      printf 'pi-worktree: note: local %s is %s behind origin/%s — pull, then re-run tidy to catch newly merged lanes\n' "$def" "$behind" "$def" >&2
    fi
  fi
  printf 'pi-worktree: tidy done — removed %d worktree(s), deleted %d merged branch(es), %d agent branch(es) still open\n' "$freed" "$merged" "$kept" >&2
  cmd_list
}

case "${1:-}" in
  create) shift; cmd_create "$@" ;;
  list|ls) shift; cmd_list "$@" ;;
  sync|status) shift; cmd_sync "$@" ;;
  remove|rm) shift; cmd_remove "$@" ;;
  finish|done) shift; cmd_finish "$@" ;;
  propose|pr) shift; cmd_propose "$@" ;;
  land|merge) shift; cmd_land "$@" ;;
  tidy|clean) shift; cmd_tidy "$@" ;;
  prune) shift; cmd_prune "$@" ;;
  -h|--help|help|"") usage ;;
  *) die "unknown command '$1' — see: pi-worktree --help" ;;
esac
