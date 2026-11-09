# pi — coding-agent sandbox

Runs [pi](https://github.com/earendil-works/pi) inside a hardened Docker
container so a misbehaving (or prompt-injected) model can only touch the
folders you mount into it, not the rest of your system.

The container itself is a long-running [herdr](https://herdr.dev) runtime:
one terminal workspace per folder, every pane and agent kept alive until
you close it — no tmux, no per-session containers. `./run.sh` is the
shortcut that drops you into the herdr TUI, right at the folder you are
in.

## Quick start

```bash
cp docker-compose.override.yml.example docker-compose.override.yml  # your mounts & defaults
cp .env.secrets.example .env.secrets && chmod 600 .env.secrets       # provider API keys
$EDITOR docker-compose.override.yml                                 # mount your folders
./run.sh ~/code/my-project                                          # open that folder in herdr
```

## Usage — one herdr, one workspace per folder

```bash
./run.sh                                  # open herdr for the current folder
./run.sh .                                # same, explicitly
./run.sh ~/code/my-project                # open that folder's workspace (creates it on first visit)
./run.sh ~/code/some-other-project        # jump to another folder's workspace
./run.sh ~/code/my-project -p "fix X"     # first open: pass extra flags to pi
./run.sh -b ~/code/my-project             # open the workspace without attaching the TUI

./run.sh ls [-w]                          # list workspaces and agents (-w: live view)
./run.sh log ~/code/my-project            # peek at a workspace's current screen
./run.sh shell ~/code/my-project          # bash in the sandbox at that folder
./run.sh kill ~/code/my-project           # close a workspace (or: kill --all)
./run.sh down                             # stop the sandbox entirely
./run.sh upgrade                          # pin the latest pi release and rebuild
./run.sh upgrade-herdr                    # pin the latest herdr release and rebuild
docker compose build                      # rebuild after changing the Dockerfile
```

The sandbox container runs [herdr](https://herdr.dev) as its main
process: a terminal workspace manager for coding agents. One **workspace**
per folder, each holding real terminal **panes** — pi agents, shells, dev
servers, tests — that herdr keeps alive until you close them. `run.sh` is
only a convenience layer: it starts the container if needed, opens (or
creates) the workspace for a folder, focuses it and attaches the herdr
TUI.

**No tmux anywhere.** Detach with herdr's `ctrl+b q` — everything keeps
running (your SSH connection can die, too). Re-attach by running
`./run.sh` again. Inside the TUI: `ctrl+b ?` shows all keys, `ctrl+b w`
navigates workspaces, and the mouse works everywhere (click panes and
sidebar entries, right-click for menus). The sidebar shows whether each
agent is working, done, or waiting for you.

First open of a folder starts pi in its workspace (with the `PI_DEFAULT_*`
model defaults, see below). Later opens just focus the workspace —
whatever is running there keeps running. Closing a workspace (`kill`) is
the only way its terminals go away; `down` stops the whole sandbox (the
workspace layout and pi sessions come back on the next start, herdr
restores them).

Paths can be host paths or container paths (`/workspace/...`) and must lie
inside one of the mounted folders; a bare folder name works too when it is
unambiguous (`./run.sh my-project` — a folder directly under one of the
mounts), and so do workspace names (`./run.sh stack/services/pi`) and ids
(`./run.sh w3`). With no path at all, `./run.sh` opens the current folder;
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
`docker-compose.override.yml` (personal, git-ignored). `run.sh` reads
exactly these mounts from the merged compose config, so a folder becomes a
valid workspace folder as soon as it is mounted. Inside the container the
mapping is `/workspace/<name>` ↔ the host folder; files are written with
your uid/gid.

## Layout

| Path | Purpose |
|---|---|
| `run.sh` | host-side convenience layer (docker compose + herdr via `docker exec`) |
| `docker-compose.yml` | the sandbox definition — universal, meant to be committed |
| `docker-compose.override.yml` | personal mounts/defaults for one machine (git-ignored; see the `.example`) |
| `.env.secrets` | provider API keys (git-ignored, chmod 600; see the `.example`) |
| `container/` | everything that makes up the image: `Dockerfile`, `pi-entrypoint.sh`, `pi-install.sh`, `install-herdr.sh`, `pi-extensions.txt`, `pi-extensions-sync.sh`, `AGENTS.md` — these run *inside* the container and are no host tools |
| `README.md` | this file |

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

Every new workspace can start pi with a default provider/model/thinking
level. Set the defaults in `docker-compose.override.yml` (or leave them
empty so each caller decides):

```bash
PI_DEFAULT_MODEL=other-model ./run.sh ~/code/my-project   # one-off override
```

| Variable | Meaning |
|---|---|
| `PI_DEFAULT_PROVIDER` | provider for the default model |
| `PI_DEFAULT_MODEL` | model pi starts with |
| `PI_DEFAULT_THINKING` | default thinking level |

The defaults are applied by `run.sh` when it starts pi in a new workspace,
and by the `pi-entrypoint` wrapper for direct `pi ...` runs. Flags you
pass yourself win: `./run.sh ~/code/my-project --model some-model` skips
the defaults entirely (including the default provider, since your model
may belong to another one).

## Credentials & git-over-ssh

- Put provider API keys in `.env.secrets` (see `.env.secrets.example`).
  Prefer narrow, short-lived keys. Never mount the host's `~/.pi/agent` —
  that is exactly the credential store this setup keeps out of the
  container.
- For git over ssh, add a read-only `~/.ssh` mount in
  `docker-compose.override.yml` (an example line is in the `.example`
  file). ssh will warn that it cannot update `known_hosts` (the mount is
  read-only) — that is intentional.

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

`run.sh` hashes `container/Dockerfile` + `container/pi-install.sh` +
`container/pi-entrypoint.sh` + `container/install-herdr.sh` +
`container/pi-extensions.txt` + `container/pi-extensions-sync.sh` into
the image label `pi.service.stamp`; when they no longer match (e.g. after
`pi-install` recorded something), it rebuilds `pi-sandbox` automatically
before starting the sandbox again. Running sessions keep their current
image.

Manual changes work the same way: edit the image sources in `container/`,
and the next `./run.sh` rebuilds. Force it with `docker compose build`.

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
./run.sh upgrade          # pin the latest npm pi release and rebuild
./run.sh upgrade 1.6.0    # pin a specific pi version and rebuild
./run.sh upgrade-herdr    # pin the latest herdr release and rebuild
```

The rebuild is immediate and all future builds keep the pinned versions.
Running workspaces keep their old binaries until restarted. Note that
`pi update` / `herdr update` *inside* a running container are not
persistent — they only change that container.
