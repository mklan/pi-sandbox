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
zip/unzip, file. If you
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

## Rules of the house

- Prefer the preinstalled tools; install only what is genuinely missing.
- Keep the Dockerfile package list alphabetical, one package per line.
- pi's own version is pinned in the Dockerfile (`ARG PI_VERSION`), and so
  is herdr (`ARG HERDR_VERSION`). Do not run `pi update` or `herdr update`
  — it would only change this throwaway container. If a version change is
  needed, tell the user to run `pi-run upgrade` or `pi-run
  upgrade-herdr` on the host.
- `pi-install` accepts plain Debian package names only (no flags, no
  paths) — do not try to work around that or to escalate privileges in any
  other way (no editing sudoers, no setuid tricks).
- You can edit everything under `/workspace`; do not attempt to reach the
  host outside of it.
