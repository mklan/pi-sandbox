# pi — coding-agent sandbox

Runs [pi](https://github.com/earendil-works/pi) inside a hardened Docker
container so a misbehaving (or prompt-injected) model can only touch the
folders you mount into it, not the rest of your system.

The container itself is a long-running [herdr](https://herdr.dev) runtime:
one terminal workspace per folder, every pane and agent kept alive until
you close it — no tmux, no per-session containers. `pi-run` is the
shortcut that drops you into the herdr TUI, right at the folder you are
in.

## Quick start

```bash
cp docker-compose.override.yml.example docker-compose.override.yml  # your mounts & defaults
cp .env.secrets.example .env.secrets && chmod 600 .env.secrets       # provider API keys
$EDITOR docker-compose.override.yml                                 # mount your folders
./install.sh                                                      # link pi-run into ~/.local/bin (once per machine)
pi-run ~/code/my-project                                          # open that folder in herdr
```

## Usage — one herdr, one workspace per folder

```bash
pi-run                                  # open herdr for the current folder
pi-run .                                # same, explicitly
pi-run ~/code/my-project                # open that folder's workspace (creates it on first visit)
pi-run ~/code/some-other-project        # jump to another folder's workspace
pi-run ~/code/my-project "fix X"      # pass a prompt: always starts a FRESH pi session
pi-run -b ~/code/my-project             # open the workspace without attaching the TUI

pi-run ls [-w]                          # list workspaces and agents (-w: live view)
pi-run log ~/code/my-project            # peek at a workspace's current screen
pi-run shell ~/code/my-project          # bash in the sandbox at that folder
pi-run kill ~/code/my-project           # close a workspace (or: kill --all)
pi-run down                             # stop the sandbox entirely
pi-run upgrade                          # pin the latest pi release and rebuild
pi-run upgrade-herdr                    # pin the latest herdr release and rebuild
docker compose build                      # rebuild after changing the Dockerfile
```

The sandbox container runs [herdr](https://herdr.dev) as its main
process: a terminal workspace manager for coding agents. One **workspace**
per folder, each holding real terminal **panes** — pi agents, shells, dev
servers, tests — that herdr keeps alive until you close them. `pi-run` is
only a convenience layer: it starts the container if needed, opens (or
creates) the workspace for a folder, focuses it and attaches the herdr
TUI.

**No tmux anywhere.** Detach with herdr's `ctrl+b q` — everything keeps
running (your SSH connection can die, too). Re-attach by running
`pi-run` again. Inside the TUI: `ctrl+b ?` shows all keys, `ctrl+b w`
navigates workspaces, and the mouse works everywhere (click panes and
sidebar entries, right-click for menus). The sidebar shows whether each
agent is working, done, or waiting for you.

First open of a folder starts pi in its workspace (with the `PI_DEFAULT_*`
model defaults, see below). Later opens with no extra args just focus the
workspace — whatever is running there keeps running. Pass a prompt and/or
pi flags and a **fresh** pi session is always started in a new pane of that
workspace, leaving the old session running (`pi-run ~/code/my-project "fix X"`).
Add `--tab` to open it in a new tab instead of splitting a pane.
Closing a workspace (`kill`) is the only way its terminals go away; `down`
stops the whole sandbox (the workspace layout and pi sessions come back on
the next start, herdr restores them).

Paths can be host paths or container paths (`/workspace/...`) and must lie
inside one of the mounted folders; a bare folder name works too when it is
unambiguous (`pi-run my-project` — a folder directly under one of the
mounts), and so do workspace names (`pi-run stack/services/pi`) and ids
(`pi-run w3`). With no path at all, `pi-run` opens the current folder;
from outside the mounts it just attaches wherever you left off.

All workspaces share the same container-local pi home volume (settings,
sessions), so provider keys from `.env.secrets` and login state are shared
across them.

## Folders the agent may work in

Everything the sandbox can touch is a bind mount under `/workspace` — one
line per folder:

```yaml
volumes:
  - /home/you/code:/workspace/code
  - /home/you/notes:/workspace/notes
```

Mount as many folders as you like, in `docker-compose.yml` (shared) or
`docker-compose.override.yml` (personal, git-ignored). `pi-run` reads
exactly these mounts from the merged compose config, so a folder becomes a
valid workspace folder as soon as it is mounted. Inside the container the
mapping is `/workspace/<name>` ↔ the host folder; files are written with
your uid/gid.

## Layout

| Path | Purpose |
|---|---|
| `pi-run` | host-side convenience layer (docker compose + herdr via `docker exec`) |
| `docker-compose.yml` | the sandbox definition — universal, meant to be committed |
| `docker-compose.override.yml` | personal mounts/defaults for one machine (git-ignored; see the `.example`) |
| `.env.secrets` | provider API keys (git-ignored, chmod 600; see the `.example`) |
| `container/` | everything that makes up the image: `Dockerfile`, `pi-entrypoint.sh`, `pi-wrapper.sh`, `pi-install.sh`, `install-herdr.sh`, `pi-extensions.txt`, `pi-extensions-sync.sh`, `AGENTS.md` — these run *inside* the container and are no host tools |
| `README.md` | this file |
| `WORKTREES.md` | how worktrees/branches work, how tasks land on `main`, how to stay tidy |

## Hardening

| Measure | Where |
|---|---|
| Non-root user matching your uid/gid (files written to mounts are yours) | `container/Dockerfile` (`USER_UID`/`USER_GID` build args) |
| Root only via `pi-install` (one narrow sudoers rule, strict package-name validation) | `container/Dockerfile`, `container/pi-install.sh` |
| Minimal capability set (subset of Docker's default, just enough for sudo/apt) | `docker-compose.yml` (`cap_drop`/`cap_add`) |
| Only the folders you mount are reachable — everything else on the host is out of reach | `docker-compose.yml` / `docker-compose.override.yml` (`volumes`) |
| Host `~/.pi/agent` **not** mounted; container keeps its own credentials/settings/sessions in the `pi-agent-home` volume | `docker-compose.yml` (`volumes`) |
| API keys in `.env.secrets` (chmod 600, git-ignored) | `.env.secrets` |
| Memory/CPU limits | `docker-compose.override.yml.example` (`deploy.resources`) |
| Host docker socket: **not** mounted by default (socket access is host-root-equivalent — opt in per machine) | `docker-compose.override.yml` (see `README.md`) |

Trade-off for the self-extending image: the rootfs is writable and
`no-new-privileges` is off (sudo needs setuid), so the agent can become
root *inside* the container through `pi-install`. The host boundary is
unchanged — mounts stay limited and root in the container cannot reach
anything else.

Not covered: **outbound network** is open, since pi needs to reach model
APIs. A model can still read the mounted folders and exfiltrate data over
the network. If a task doesn't need net access, restrict it, e.g. attach
the service to an `internal: true` network, or use a firewall.

Prompt injection can still make the model do damage *inside* the mounted
folders — commit/push before long unsupervised runs so you can recover.

## Default model

Every pi session can start with a default provider/model/thinking level.
Set the defaults in `docker-compose.override.yml` (or leave them empty so
each caller decides):

```bash
PI_DEFAULT_MODEL=other-model pi-run ~/code/my-project   # one-off override
```

| Variable | Meaning |
|---|---|
| `PI_DEFAULT_PROVIDER` | provider for the default model |
| `PI_DEFAULT_MODEL` | model pi starts with |
| `PI_DEFAULT_THINKING` | default thinking level |

The defaults apply everywhere: `pi-run` passes them when it starts pi in a
new workspace, and a `pi` wrapper (`container/pi-wrapper.sh`, installed as
`/home/pi/.local/bin/pi`, first in `PATH`) injects them for a bare `pi`
typed in any herdr pane — so `ctrl+c` out of pi and restarting it by hand
keeps the same model. Flags you pass yourself win: `pi --model some-model`
skips the defaults entirely (including the default provider, since your
model may belong to another one). Management subcommands (`install`,
`list`, `auth`, ...) never get model flags injected.

## Parallel agents in one repo (worktrees)

Two agents editing the same checkout clobber each other. Inside the
sandbox, parallel agents in one repo each get their own git worktree on
their own feature branch. The full guide — mental model, who merges when,
tidiness, troubleshooting — lives in **`WORKTREES.md`** (start there):

```bash
pi-run shell ~/code/my-project                  # in the repo root, on main
pi-worktree create login-form                   # .worktrees/login-form on agent/login-form
# ... start the agent with its cwd in .worktrees/login-form ...
pi-worktree propose login-form                  # agent: pushes, opens a PR, removes the worktree
# ... you review the PR, merge it, then ...
pi-worktree tidy                                # you: drop the merged leftovers (or: land login-form to merge locally)
```

`pi-run <folder> "<prompt>"` on an already-open workspace does this
isolation automatically: the fresh session starts in a new
`agent/<slug>` worktree instead of the shared checkout, so parallel
agents never fork history. The prompt is prefixed with the
worktree/branch context (including a stale-base warning when the local
branch trails `origin`).

Rule of thumb: agents finish branches, humans land them. Removing a
worktree never loses committed work (it lives on the branch) — review the
branch, `land` it, and `tidy` whenever the list looks cluttered.
The helper ships in the image (`container/pi-worktree.sh`); host edits to
it are picked up on container restart and baked in at the next rebuild,
like `pi-wrapper.sh`. Agents follow the same lifecycle from
`container/AGENTS.md` "Parallel agents".

## Credentials & git-over-ssh

- Put provider API keys in `.env.secrets` (see `.env.secrets.example`).
  Prefer narrow, short-lived keys. Never mount the host's `~/.pi/agent` —
  that is exactly the credential store this setup keeps out of the
  container.
- For git over ssh, forward the host's ssh-agent instead of mounting
  keys (example lines are in the `.example` file):
  ```yaml
  environment:
    SSH_AUTH_SOCK: /ssh-agent
  volumes:
    - /run/user/1000/ssh-agent.socket:/ssh-agent
    - /home/you/.ssh/known_hosts:/home/pi/.ssh/known_hosts:ro
  ```
  Unlock once on the host with `github-ssh-unlock`, and the container's
  ssh uses the decrypted key from the agent's RAM — `ssh-add -l` inside
  must list it. Never mount the whole `~/.ssh` (read-only or not): that
  exposes private keys to the agent, and the encrypted key file alone is
  useless inside anyway (hence `Permission denied (publickey)` without
  the agent socket). Mount only `known_hosts`, and never `~/.ssh/config`
  — its `IdentityFile`/`IdentitiesOnly` lines point at key files that do
  not exist in the container and would break agent auth.

## Self-extending image

The agent is guided by `container/AGENTS.md` (mounted at
`/home/pi/.pi/agent/AGENTS.md`, so pi loads it in every session regardless
of the working folder). When a tool is missing it runs:

```bash
pi-install <package> [package...]     # e.g. pi-install imagemagick
```

That installs the package into the running container and records it in the
apt list of `container/Dockerfile` (one line above the cleanup line; the
Dockerfile is mounted at `/opt/pi-service/Dockerfile` for this), keeping
the Dockerfile the single source of truth.

`pi-run` hashes `container/Dockerfile` + `container/pi-install.sh` +
`container/pi-entrypoint.sh` + `container/pi-wrapper.sh` +
`container/install-herdr.sh` + `container/pi-extensions.txt` +
`container/pi-extensions-sync.sh` into
the image label `pi.service.stamp`; when they no longer match (e.g. after
`pi-install` recorded something), it rebuilds `pi-sandbox` automatically
before starting the sandbox again. Running sessions keep their current
image.

Manual changes work the same way: edit the image sources in `container/`,
and the next `pi-run` rebuilds. Force it with `docker compose build`.

## Image variants (default / android)

The image is multi-stage (`container/Dockerfile`), based on Ubuntu LTS
(`ARG UBUNTU_VERSION`, currently 24.04 — universal, and what the Android
toolchain officially supports):

| Stage / sandbox | Contents | Image |
|---|---|---|
| `base` | Ubuntu + everything every sandbox needs: general tooling (git, gh, curl/jq/ripgrep/fd, ssh client, Chrome for browser tests), Node.js, Docker CLI/compose plugin, herdr, pi and vibeflow CLIs + preinstalled pi extensions, pi user, pi-install, entrypoint, helpers | build layer only (never run directly) |
| `default` | base alias — adds nothing (kept as the `pi-sandbox` build target; Node.js lives in base because pi/vibeflow are Node apps) — the daily driver | `pi-sandbox` |
| `android` | default + OpenJDK 17 + Android SDK (cmdline-tools, platform-tools, one platform + build-tools, licences pre-accepted) + Gradle + Kotlin — builds Kotlin/Android apps (`gradle assembleDebug`, lint, unit tests) | `pi-sandbox-android` |

Pick the sandbox per invocation, or export it for the whole shell:

```bash
pi-run ~/code/my-project                  # default sandbox
pi-run -s android ~/code/android-app      # android sandbox
pi-run --sandbox android shell ~/code/android-app   # shell there
PI_SANDBOX=android pi-run ~/code/android-app        # sticky for the shell
# alternative sticky default for this machine: add PI_SANDBOX=android to .env
pi-run sandboxes                          # list variants + which is built
```

Per-workspace default: a `.pi-sandbox` file in the project folder pins the
sandbox for that folder (searched upward to the mount root, so opening a
subdir still picks it up):

```bash
pi-run sandboxes --set android ~/code/android-app   # writes ~/code/android-app/.pi-sandbox
pi-run ~/code/android-app                            # now uses android, no flag needed
pi-run sandboxes ~/code/android-app                 # shows the workspace default
pi-run sandboxes --unset ~/code/android-app         # remove it again
```

The file holds one line, e.g. `sandbox=android` (`PI_SANDBOX=android`,
`sandbox: android` and a bare `android` work too). Precedence: the
`-s`/`--sandbox` flag, then the `PI_SANDBOX` env var, then the workspace
`.pi-sandbox` file, then `default`. The file is plain text in your project
— commit it when the whole team should share the default, or git-ignore it
for a personal choice.

Switching variants recreates the container (one `docker compose build` +
`up` behind the scenes, automatic via the image stamp) — workspaces, panes
and pi sessions are restored from the `pi-agent-home` volume, so nothing is
lost. Both variants share the same mounts, `.env.secrets` and
`docker-compose.override.yml`; no override changes are needed to switch.

Notes for the android sandbox:

- Extend the SDK without root: `/opt/android-sdk` is pi-owned, so
  `sdkmanager "platforms;android-35"` just works (agents: prefer this over
  `pi-install` for SDK packages).
- No emulator system images are baked in (GBs, and they need KVM) — run the
  emulator on the host and `adb` into it from the sandbox.
- Keep the toolchain current: `pi-run upgrade-kotlin [version]` and
  `pi-run upgrade-gradle [version]` pin the versions in the Dockerfile like
  every other component.

## Docker for e2e tests

The `base` stage layers our main stack on top of Ubuntu: Node.js from
the official tarball (`ARG NODE_VERSION`), plus the Docker CLI and the
compose plugin as pinned static binaries (`ARG DOCKER_VERSION`, `ARG
COMPOSE_VERSION`), the pi and vibeflow CLIs and the preinstalled pi
extensions. (`default` is a bare alias of base, so these live in every
sandbox.) Bump them with:

```bash
pi-run upgrade-node       # newest Node v24.x, or: pi-run upgrade-node 24.22.2
pi-run upgrade-docker     # newest stable CLI, or: pi-run upgrade-docker 29.9.3
pi-run upgrade-compose    # newest release, or: pi-run upgrade-compose v5.7.0
```

There is no daemon inside the sandbox: `docker` talks to the **host**
daemon through `/var/run/docker.sock` (docker-outside-of-docker — a
privileged DinD daemon would void the hardening above). The socket mount
is opt-in per machine in `docker-compose.override.yml` (see the
`.example`); the next `pi-run` then rebuilds automatically with the
host's docker GID (it is part of the image stamp, manual fallback:
`DOCKER_GID=$(getent group docker | cut -d: -f3) docker compose build`).

Two caveats agents must respect (also in `container/AGENTS.md`): socket
access is host-root-equivalent, and bind mounts in other projects'
compose files resolve on the host, where `/workspace/...` paths do not
exist — every mount is therefore aliased at its real host path (see the
`.example`) and agents translate via `pi-hostpath <sandbox-path>` before running any docker command that creates mounts.

## Pi extensions
Base pi extensions (packages, e.g. subagents) are declared in
`container/pi-extensions.txt` — one `pi install` source per line:

```text
npm:pi-subagents
npm:my-tools@1.2.0   # pin a version for reproducible builds
```

The build installs every line into the image (fresh volumes start with
them); the container entrypoint re-checks the file on every start and
installs whatever is declared but missing, so adding a line takes effect
on the next container start (`docker compose restart` applies it now)
even before the automatic rebuild bakes it in. Inside a session,
`pi install <source>` still works for the moment, but only a line in
`pi-extensions.txt` survives fresh volumes and rebuilds.

## Upgrading pi and herdr

Both tools are pinned in `container/Dockerfile` (`ARG PI_VERSION`,
`ARG HERDR_VERSION`) — persistent, like everything else in the image:

```bash
pi-run upgrade          # pin the latest npm pi release and rebuild
pi-run upgrade 1.6.0    # pin a specific pi version and rebuild
pi-run upgrade-herdr    # pin the latest herdr release and rebuild
```

The rebuild is immediate and all future builds keep the pinned versions.
Running workspaces keep their old binaries until restarted. Note that
`pi update` / `herdr update` *inside* a running container are not
persistent — they only change that container.
