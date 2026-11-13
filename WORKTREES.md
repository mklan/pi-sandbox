# Worktrees & branches — parallel agents in one workspace

Goal: several agents work on different tasks in the same repo **at the same
time**, in one sandbox workspace, without clobbering each other — and every
finished task reliably lands on `main`.

## The mental model (30 seconds)

- **One task = one worktree = one branch.** An agent never edits the shared
  checkout; it gets its own directory (a git worktree) on its own branch.
- **The main checkout stays on `main`, clean, unedited** while workers run.
  It is the landing strip, not a workplace.
- Worktrees live at `<repo>/.worktrees/<slug>` on branches named
  `agent/<slug>` (`login-form` → `.worktrees/login-form`, branch
  `agent/login-form`). Nested on purpose: a sibling directory could fall
  outside the sandbox's `/workspace` mounts and never reach the host.
- **Removing a worktree never loses committed work** — it lives on the
  branch. Only *uncommitted* work is at risk, and the helper refuses to
  touch dirty worktrees unless you pass `--force`.

## The lifecycle

| Step | Who | Command (inside the sandbox, repo root) | What it does |
|---|---|---|---|
| 1. Start | you, or `pi-run` automatically | `pi-worktree create <slug>` | new worktree + `agent/<slug>` branch off current `main` |
| 2. Work | agent | (commits in its worktree) | agent stays in its worktree the whole task |
| 3. Propose | agent | `pi-worktree propose <slug>` | pushes, opens a PR with `gh`, removes the worktree |
| 4. Review | you | review + merge the PR | human review on GitHub |
| 5. Tidy | you | `git pull` + `pi-worktree tidy` | drops the merged worktrees/branches locally |

(`finish` pushes without a PR — fallback for when `gh`/`origin` is
unavailable. `land` merges locally instead of via the PR — same result,
the PR closes itself as merged once you push `main`.)

Steps 1–3 can happen in parallel for as many tasks as you like. Steps 4–5
are serial, deliberate, and human-owned: **agents never merge to `main`.**

### 1. Starting work

Manual (herdr agents, subagents):

```bash
pi-run shell ~/code/my-project        # in the repo root, on main, clean tree
pi-worktree create login-form         # .worktrees/login-form on agent/login-form
# ... start the agent with its cwd in .worktrees/login-form ...
```

Automatic: `pi-run <folder> "<prompt>"` on an already-open workspace starts
the fresh session in its own `agent/<slug>` worktree (slug derived from
your prompt words) and prefixes the prompt with the worktree/branch
context — including a stale-base warning when local `main` trails
`origin`. Same rules apply to the auto-created ones.

The kanban flow (`vibeflow`, see the workspace hook) is this automation
end to end: moving a ticket to `todo` fires
`pi-run -b --tab . "<task prompt>"`, so each task gets its own worktree;
the agent moves the ticket to `review` when done.

### 2–3. Working and proposing (agent side)

The agent commits on its branch and runs `pi-worktree propose <slug>` at
the end. That pushes (`-u origin`), opens a PR against the default branch
with `gh --fill` (non-interactive; `--draft` for work-in-progress), and
removes its own worktree — then reports the **PR URL** back. Removing the
worktree at this point is safe: the commits live on the local branch, the
remote branch and the PR, so nothing can get lost even if the machine
vanishes. Re-running `propose` just updates the PR (it detects an already
open one instead of duplicating it). `finish` is the fallback when `gh`
or `origin` is unavailable: push without a PR, report the branch name.
`finish --keep` keeps the worktree around (debugging); `finish --no-push`
skips the push (offline).

### 4–5. Landing on `main` (human side, the important part)

**When:** a task is done, its tests pass, and you have reviewed the PR.
Merge reviewed PRs promptly — same day if possible. Stockpiled
`agent/*` branches go stale (their base drifts from `main`) and turn one
clean merge into a conflict-resolution session. Never let parallel work
commit directly to `main`, and never leave `backup-*` lanes lying around.

**How:** the Merge button on the PR. A merged PR does **not** clean up
your machine — GitHub cannot reach it, so the local worktree, the local
branch and the remote branch all stay. That is what step 5 is for.
Alternatives from anywhere in the repo (the merge itself always runs in the
main checkout):

```bash
pi-worktree land login-form           # merge agent/login-form into main, clean up
pi-worktree land login-form -r        # also delete the branch on origin
```

`land` refuses when the main checkout or the worker tree is dirty, switches
the main checkout to the default branch (`origin/HEAD`, else `main`, else
`master`), fast-forwards it when it only trails its upstream, merges with
`--no-ff` (every task stays one visible merge commit), deletes the local
branch, removes the worktree if it is still there, and prunes. If the merge
conflicts it stops in the main checkout for you to resolve — the worker
branch is untouched.

Merge style is `--no-ff` on purpose (both the PR's merge commit and `land`
use it): `git log --first-parent` then reads as one entry per task, and
reverting a task is one `git revert -m 1`. Tip: enable *Automatically
delete head branches* in the repo settings so merged PRs vanish on origin
by themselves.

### 6. Keeping things tidy

- `pi-worktree list` — every worktree with branch, clean/dirty, HEAD.
- `pi-worktree sync` (alias: `status`) — read-only: fetches `origin`, then
  shows each worktree's branch as `+ahead/-behind` vs its upstream. Run
  this before landing to spot stale lanes.
- `pi-worktree tidy` (alias: `clean`) — the janitor: prunes stale metadata,
  `fetch --prune`, removes worktrees whose branch is already merged
  (locally **or** on `origin` — i.e. PRs merged on GitHub that you have
  not pulled yet), and deletes the merged local `agent/*` branches.
  Never deletes unmerged work, never touches dirty worktrees or remotes.
  Typical sequence after merging PRs: `git pull && pi-worktree tidy`. If
  local `main` trails `origin`, `tidy` says so — pull and re-run to catch
  the newly merged lanes.
- `pi-run ls` (on the host) — workspaces and agent states; for git state,
  `pi-run shell <folder> pi-worktree sync`.

House rules:

- `.worktrees/` is hidden from `git status` via `.git/info/exclude` (not
  `.gitignore`) — never commit it, never create it by hand.
- One writer per worktree. Never check out a worker's branch anywhere else
  while it runs; never commit to `main`/`master` from a worktree.
- Worktrees isolate *files*, not everything: give each agent its own ports,
  services, and DB files; coordinate shared devices/cloud resources in the
  task prompt.
- Ignored files are **not** copied into a new worktree — reinstall deps
  (`npm ci`, …), copy needed `.env`/local files from the root, never commit
  secrets.
- A worker whose base went stale rebases **inside its own worktree**
  (`git pull --rebase origin main`); conflicts are that agent's job, on its
  branch.

## Abandoning a task

Work turned out useless? The branch still holds the commits, so nothing is
lost either way:

```bash
pi-worktree remove login-form --delete-branch   # drop worktree + branch
pi-worktree remove login-form                   # drop worktree, keep branch for later
gh pr close agent/login-form --delete-branch    # close the PR too, if one was opened
```

`remove` refuses a dirty tree unless `--force` (which discards uncommitted
work). `finish`ed branches whose worktree is already gone can still be
landed (`land <branch>`) or dropped (`git branch -D agent/<slug>`).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `finish`/`land`/`remove` says *dirty* | uncommitted work in the (worker or main) tree | commit/stash there first; `remove --force` only to discard |
| stale-base warning in the agent prompt | local `main` trails `origin` | `git pull --rebase` in the main checkout before creating/landing |
| `land` stops with conflicts | both lanes touched the same lines | resolve in the main checkout, commit, then `pi-worktree remove <branch> --delete-branch` |
| `refusing to touch the main checkout` | you targeted the main worktree | target the worker (`land`/`remove <slug>`) |
| worktree gone, branch remains | `finish`/`propose` already removed it | `land <branch>` or `git branch -D agent/<slug>`; `tidy` cleans merged ones |
| `propose` says not logged in / no `gh` | `gh` missing or unauthenticated, or no `origin` | `gh auth login`, or fall back to `finish` (no PR) and report the branch |
| PR merged but local branch/worktree linger | GitHub cannot clean your machine | `git pull && pi-worktree tidy` — that is the step that reaps them |
| `not inside a git repo` | plain folder, no git | copy the folder per agent (`cp -a`) — worktrees need git |

## Reference

- Helper source: `container/pi-worktree.sh` (`pi-worktree --help` prints the
  same lifecycle). Host edits are picked up on container restart and baked
  in at the next rebuild — it is part of the image stamp.
- Agent rules (what the agent itself is told): `container/AGENTS.md`
  “Parallel agents”.
- Auto-isolation for `pi-run "<prompt>"` sessions: `maybe_isolate_worktree`
  in `pi-run`.
