# pi — coding-agent sandbox

Runs [pi](https://github.com/earendil-works/pi) inside a hardened Docker
container so a misbehaving (or prompt-injected) model can only touch the
folders you mount into it, not the rest of your system.

## Quick start

```bash
cp docker-compose.override.yml.example docker-compose.override.yml  # your mounts & defaults
cp .env.secrets.example .env.secrets && chmod 600 .env.secrets       # provider API keys
$EDITOR docker-compose.override.yml                                 # mount your folders
./run.sh ~/code/my-project                                          # open pi in that folder
```

## Usage — one session per folder

```bash
./run.sh                                  # resume the last opened session (any folder)
./run.sh .                                # current folder: its session, or a new one
./run.sh ~/code/my-project                # open pi in that folder (creates/attaches a session)
./run.sh ~/code/some-other-project        # parallel session in another folder
./run.sh ~/code/my-project -p "fix X"     # pass extra flags to pi
./run.sh -b ~/code/my-project             # start in the background without attaching

./run.sh ls [-w]                          # list sessions (-w: live view, ctrl+c to stop)
./run.sh log ~/code/my-project            # peek at a session's current screen
./run.sh shell ~/code/my-project          # bash in that session's container
./run.sh kill ~/code/my-project           # stop a session (or: kill --all)
./run.sh upgrade                          # pin the latest pi release and rebuild
docker compose build                      # rebuild after changing the Dockerfile
```

`ls` shows each session's folder, state (attached/detached), age, and the
last meaningful line pi is currently showing — handy to check on detached
background runs.

Each folder gets its own tmux session (`pi-<folder>`) running its own
sandboxed container. **Detach with your tmux prefix + d** (default
`Ctrl-b d`) — pi keeps working in the background; re-attach any time by
running `./run.sh <path>` again. Sessions disappear when pi exits.

Paths can be host paths or container paths (`/workspace/...`) and must lie
inside one of the mounted folders; a bare folder name works too when it is
unambiguous (`./run.sh my-project` — a folder directly under one of the
mounts, or the name of an existing session).

With no path at all, `./run.sh` resumes the most recently opened session
regardless of the current folder (or starts one in the current folder when
nothing is running). Pass `.` to explicitly mean the current folder.

All sessions share the same container-local pi home volume (settings,
sessions), so provider keys from `.env.secrets` and login state are shared
across sessions.

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
valid session folder as soon as it is mounted. Inside the container the
mapping is `/workspace/<name>` ↔ the host folder; files are written with
your uid/gid.

## Layout

| Path | Purpose |
|---|---|
| `run.sh` | host-side session manager (tmux + docker compose) |
| `docker-compose.yml` | the sandbox definition — universal, meant to be committed |
| `docker-compose.override.yml` | personal mounts/defaults for one machine (git-ignored; see the `.example`) |
| `.env.secrets` | provider API keys (git-ignored, chmod 600; see the `.example`) |
| `container/` | everything that makes up the image: `Dockerfile`, `pi-entrypoint.sh`, `pi-install.sh`, `AGENTS.md` — these run *inside* the container and are no host tools |
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

Every session can start with a default provider/model/thinking level,
applied by the `pi-entrypoint` wrapper. Set the defaults in
`docker-compose.override.yml` (or leave them empty so each session's
caller decides):

```bash
PI_DEFAULT_MODEL=other-model ./run.sh ~/code/my-project   # one-off override
```

| Variable | Meaning |
|---|---|
| `PI_DEFAULT_PROVIDER` | provider for the default model |
| `PI_DEFAULT_MODEL` | model every session starts with |
| `PI_DEFAULT_THINKING` | default thinking level |

Flags you pass yourself win: `./run.sh ~/code/my-project --model some-model`
skips the defaults entirely (including the default provider, since your
model may belong to another one).

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
`container/pi-entrypoint.sh` into the image label `pi.service.stamp`; when
they no longer match (e.g. after `pi-install` recorded something), it
rebuilds `pi-sandbox` automatically before starting the next session.
Running sessions keep their current image.

Manual changes work the same way: edit the image sources in `container/`,
and the next `./run.sh` rebuilds. Force it with `docker compose build`.

## Upgrading pi

pi itself is pinned via `ARG PI_VERSION` in `container/Dockerfile` —
persistent, like everything else in the image:

```bash
./run.sh upgrade          # pin the latest npm release and rebuild
./run.sh upgrade 1.6.0    # pin a specific version and rebuild
```

The rebuild is immediate and all future builds keep the pinned version.
Running sessions keep their old pi until restarted. Note that `pi update`
*inside* a session is not persistent — it only changes that throwaway
container.
