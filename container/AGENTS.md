# Sandbox agent guide

You are running inside the pi sandbox container. The host system outside
`/workspace` is not reachable. One or more folders from the host are
mounted under `/workspace/<name>` — run `ls /workspace` to see which ones
this session has. Everything you write there lands on the host, owned by
the user; treat the rest of the container as disposable.

## How this container runs: herdr

This container's main process is **herdr** (`herdr server`), a terminal
runtime for coding agents (herdr.dev). Every shell, agent and long-running
command here lives in a herdr pane and keeps running across SSH
disconnects, TUI clients attaching/detaching, and even container
recreations (herdr restores the workspace layout and resumes pi sessions
from its state in `/home/pi/.pi/agent/herdr`). The user attaches with the
herdr TUI from the host (`pi-run` on the host side) — there is no tmux
involved anywhere.

If `test "${HERDR_ENV:-}" = 1` succeeds, **you are running inside a herdr
pane** and can steer the session around you. The full control manual is
embedded in the binary:

    herdr --skill          # how to control panes, workspaces and agents
    herdr --help           # every command

Typical use: split a pane to run tests or a dev server next to you
(`herdr pane split --current --direction right --cwd "$PWD" --no-focus`),
start helper agents (`herdr agent start <name> --kind codex --pane <id>`),
read their output (`herdr agent read <name>`), and wait for them
(`herdr agent wait <name>`). Use `--no-focus` for background work so you
do not steal the user's view.

The pi integration (installed by the entrypoint, `herdr integration
status`) reports your working/blocked/done status to herdr's sidebar and
enables session restore — leave it in place.

**Never** run `herdr server stop` and never kill the `herdr server`
process — it is PID 1 and the keeper of every terminal here; the container
dies with it. Do not close workspaces, tabs or panes you did not create
unless the user asks.

## Missing packages and tools

The image ships common tooling: git, gh (GitHub CLI), ripgrep (rg), fd,
curl, jq, less, procps, python3, make, g++, openssh-client, tmux,
zip/unzip, file, plus Google Chrome (browser tests). The `default`
sandbox adds Node.js, the Docker CLI and the pi/vibeflow CLIs; the
`android` sandbox adds OpenJDK 17, the Android SDK, Gradle and Kotlin —
see README.md "Image variants". The host picks the sandbox (`pi-run
-s android ...` / `PI_SANDBOX=android`); you cannot switch it from in
here. If you
need anything else:

1. Install it on the fly:

       pi-install <package> [package...]
       # e.g.  pi-install imagemagick poppler-utils

   This installs immediately (apt-get, as root through a narrow sudoers
   rule — it is the only way to become root here) and records the package
   in the image Dockerfile.

2. Make sure it got recorded: the apt package list lives in
   `/opt/pi-service/Dockerfile` (the image's Dockerfile, bind-mounted from
   the host; one package per line in the marked block). If `pi-install`
   could not write the file (e.g. warning about a missing Dockerfile), add
   the package name there yourself and tell the user where to add it.

3. Never leave packages installed "by hand" only — the Dockerfile is the
   single source of truth for what the image contains.

The Dockerfile and the `pi-install` helper are hashed into an image label;
the session manager on the host notices when they change and rebuilds the
image before starting the next session. You cannot rebuild it yourself —
just record the package and tell the user it takes effect for new sessions
(running sessions keep their current image).

## Pi extensions (packages)

Base extensions (e.g. subagents) are declared in
`container/pi-extensions.txt` in the service repo — one `pi install`
source per line, e.g. `npm:pi-subagents` (pin versions like
`npm:pkg@x.y.z` for reproducible builds). If the service repo is mounted
under `/workspace`, edit that file directly; otherwise tell the user
which line to add.

When you need an extension:

1. Add its source line to `container/pi-extensions.txt` (keep the list
   alphabetical). This is the single source of truth: the image
   build installs it, and the container entrypoint installs whatever is
   declared but missing on every start.
2. Install it right now too, so you can use it immediately:

       pi install <source>

   This only lands in the container's settings volume — step 1 is what
   makes it survive fresh volumes and rebuilds.
3. Make sure it got recorded: the file is bind-mounted at
   `/opt/pi-service/pi-extensions.txt` (read-only). If that mount is
   missing, add the line on the host yourself and tell the user where.

You cannot rebuild the image yourself — the host rebuilds automatically
when the list changes (it is part of the image stamp). The entrypoint
picks up added lines on the next container start; tell the user a
restart applies them (`docker compose restart`) if the sandbox is
already running.

## GitHub CLI (`gh`) and git push/pull

`gh` is preinstalled. Its credentials live in `~/.config/gh`, which is a
symlink into the pi-agent-home volume (`/home/pi/.pi/agent/gh`) — so a
login survives container recreation. To authenticate, either run
`gh auth login` yourself, or put `GH_TOKEN=<token>` (or `GITHUB_TOKEN`)
into `services/pi/.env.secrets` on the host (loaded via `env_file`).
The token needs scopes `repo`, `read:org`, and `workflow` (plus
`delete_repo` if you ever need to remove repos).

git is configured system-wide to use gh as its HTTPS credential helper
(`credential.helper = !gh auth git-credential`), so `git push`/`git pull`
over HTTPS work automatically once `gh auth status` shows a login — no
separate git credentials or SSH keys needed. Creating repos works too:
`gh repo create ...`.

Git over SSH works too when the host forwards its ssh-agent (the
`/ssh-agent` mount, see the service README): the container holds no
private keys, it asks the host's agent. If an SSH remote fails with
`Permission denied (publickey)` plus `Could not open a connection to your
authentication agent`, the agent socket is not forwarded or the key is
still locked — run `github-ssh-unlock` on the host (never copy private
keys into the container).

## Committing and pushing (scope)

When the user says "commit", "push", or "commit and push" (or asks to
stage, commit, or publish changes) without naming a repo, scope is **only
the current workspace**: the repo that contains the current working
directory (e.g. `services/pi` is its own repo — stage, commit, and push
there only). This also applies to bare "commit this" / "push it"
requests: they always mean the current workspace, never more.

- Never commit or push parent repos (e.g. `/workspace/stack`) or sibling
  folders as part of such a request — even if the parent shows the
  workspace as a modified submodule. Mention it instead if the parent
  looks dirty, and let the user decide.
- If the request names a different path or repo explicitly, that target
  wins over the current-workspace default.
- Committing never pushes unless the user said "push" (or "commit and
  push"). Pushing never switches branches — push the current branch
  (ask first if it has no upstream or the remote has diverged).

## Parallel agents: one worktree per agent

When more than one agent works in the same repo at the same time — herdr
agents, pi subagents, or parallel `pi-run ... "prompt"` sessions —
every agent gets its own **git worktree on its own feature branch**.
Never let two agents edit the same checkout: they clobber each other's
files, builds, and git state. This is the standard approach (same pattern
as CI checkouts and the worktree flows in Claude Code / Cursor / Jules):
cheap (one shared `.git`, no re-clone), fully isolated working tree per
agent, and the branch keeps the work after the worktree directory is gone.

Use the `pi-worktree` helper (on `PATH` in every session) — do not
hand-roll `git worktree` commands with ad-hoc paths and branch names:

```bash
pi-worktree create <slug> [--base main]   # <root>/.worktrees/<slug> on branch agent/<slug>
pi-worktree list                           # all worktrees, branches, clean/dirty
pi-worktree finish <slug>                  # push branch + remove worktree (end of task)
pi-worktree remove <slug> [--delete-branch]# remove worktree, keep the branch by default
pi-worktree prune                          # drop stale metadata
```

### Lifecycle

1. **Create (supervisor, in the repo root, on `main`, clean tree):**
   `pi-worktree create <slug>` — one short lowercase slug per task
   (`login-form`, `billing-csv`). The branch is `agent/<slug>`;
   collisions auto-suffix (`-2`, `-3`).
2. **Start the agent IN the worktree** and keep it there for the whole
   task — e.g. `herdr pane split --current --direction right --cwd
   <path> --no-focus`, then `herdr agent start <name> --kind pi --pane
   <id>`. Never `cd` back to the shared root to edit files.
3. **Set up inside the worktree:** ignored files are NOT copied —
   reinstall deps (`npm ci`, …), copy needed `.env`/local files from the
   root, never commit secrets. Give each agent its own ports/services.
4. **Finish (agent):** commit on its branch, then `pi-worktree finish
   <slug>` — pushes (`-u origin`) and removes its own worktree.
   Report the **branch name** back to the supervisor. Cleanup is
   automatic at this point: removing a worktree never loses committed
   work (it lives on the branch); only uncommitted work is at risk, and
   `finish`/`remove` refuse a dirty tree unless `--force`.
5. **Merge (supervisor, in the main checkout):** review, `git switch
   main && git merge --no-ff agent/<slug>`, then `git branch -d
   agent/<slug>` and `pi-worktree prune`.

### Rules

- One branch per worktree. Never check out a worker's branch anywhere
  else while it runs; never commit to `main`/`master` from a worktree.
- The main checkout stays on `main` and clean — the supervisor does not
  edit files there while workers run.
- One writer per worktree — agents never touch another agent's worktree.
- Shared mutable state still collides (DB files, fixed-port dev servers,
  devices/cloud resources) — coordinate ports and allocations in the task
  prompt; worktrees isolate files, not everything.
- Rebase a worker onto fresh `main` inside its own worktree when needed;
  conflicts are that agent's job, resolved on its branch.
- Non-git folders cannot use worktrees — copy the folder (`cp -a`, one
  copy per agent) instead.

## Docker for e2e tests (host daemon)

`docker` and `docker compose` are on `PATH`, but there is NO daemon
inside — the CLI talks to the host daemon through a bind-mounted
`/var/run/docker.sock` (docker-outside-of-docker; a privileged DinD
daemon would void the hardening below, so it is deliberately not used).

- Enabled per machine via the socket mount in
  `docker-compose.override.yml`, plus one rebuild with the host's docker
  GID (`DOCKER_GID=$(getent group docker | cut -d: -f3) docker compose
  build`). If `docker ps` fails with permission denied, the mount or the
  GID is wrong — that is the expected signal, never `chmod` the socket.
- **Path mapping:** the host daemon resolves bind mounts on the HOST,
  where `/workspace/...` does not exist. For any docker command that
  creates bind mounts (`compose up/run`, `-v`), `cd` to the REAL host
  path first — every `/workspace/<name>` is also mounted at its real
  path. Translate with `pi-hostpath <sandbox-path>` (asks the daemon,
  falling back to the kernel mount table — never guess; it exits 2
  outside host mounts):
  `cd "$(pi-hostpath /workspace/stack/services/startpage/fe/docker)"`.
  Verify afterwards: `docker inspect <container> --format '{{ .Mounts }}'`
  must show host-valid sources. When in doubt, ask the supervisor for
  the host path instead of guessing.
- **Restraint:** the daemon is shared with everything on the host. Name
  test resources per task (`<slug>-...`), always `down -v` when done,
  and never run host-wide commands (`docker system prune`, stopping or
  touching other projects' containers/images).
- Prefer `docker compose up --build --abort-on-container-exit` for e2e
  runs so failures surface and nothing is left behind.

## Rules of the house

- Prefer the preinstalled tools; install only what is genuinely missing.
- Keep the Dockerfile package list alphabetical, one package per line.
- Pinned versions live in the Dockerfile (`ARG PI_VERSION`, `ARG
  HERDR_VERSION`, `ARG NODE_VERSION`, `ARG DOCKER_VERSION`, `ARG
  COMPOSE_VERSION`, `ARG KOTLIN_VERSION`, `ARG GRADLE_VERSION`, ...). Do
  not run `pi update` or `herdr update`
  — it would only change this throwaway container. If a version change is
  needed, tell the user to run `pi-run upgrade` or `pi-run
  upgrade-herdr` on the host.
- `pi-install` accepts plain apt package names only (Ubuntu-based image; no flags, no
  paths) — do not try to work around that or to escalate privileges in any
  other way (no editing sudoers, no setuid tricks).
- You can edit everything under `/workspace`; do not attempt to reach the
  host outside of it.
