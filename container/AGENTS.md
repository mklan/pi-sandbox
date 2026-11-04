# Sandbox agent guide

You are running inside the pi sandbox container. The host system outside
`/workspace` is not reachable. One or more folders from the host are
mounted under `/workspace/<name>` — run `ls /workspace` to see which ones
this session has. Everything you write there lands on the host, owned by
the user; treat the rest of the container as disposable.

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

## Rules of the house

- Prefer the preinstalled tools; install only what is genuinely missing.
- Keep the Dockerfile package list alphabetical, one package per line.
- pi's own version is pinned in the Dockerfile (`ARG PI_VERSION`). Do not
  run `pi update` — it would only change this throwaway container. If a
  pi version change is needed, tell the user to run `./run.sh upgrade` on
  the host.
- `pi-install` accepts plain Debian package names only (no flags, no
  paths) — do not try to work around that or to escalate privileges in any
  other way (no editing sudoers, no setuid tricks).
- You can edit everything under `/workspace`; do not attempt to reach the
  host outside of it.
