# Pi coding-agent sandbox image.
#
# Build from the repository root:  docker compose build  (or pi-run)
#
# pi runs as a non-root user whose uid/gid match the host user (build args
# USER_UID/USER_GID, default 1000), so files written into the mounted
# /workspace folders are owned by you instead of root.
#
# Self-extending image: inside a session the agent installs missing tools
# with `pi-install <pkg>` — that installs into the running container and
# records the package in the apt list below, so it is baked into the image
# at the next build. The file is mounted into the running container at
# /opt/pi-service/Dockerfile (see docker-compose.yml); `pi-run` compares
# the PI_STAMP label against the image sources and rebuilds automatically
# before starting a new session.

FROM node:24-bookworm-slim

# --- apt packages (one per line, keep alphabetical) ----------------------
# pi-install appends packages on the fly here (directly above the cleanup
# line), so everything the agent ever needed is part of the next build.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    fd-find \
    file \
    g++ \
    git \
    jq \
    less \
    make \
    openssh-client \
    procps \
    python3 \
    ripgrep \
    sudo \
    tmux \
    unzip \
    zip \
    gh \
    libcups2 \
    libasound2 \
    libatspi2.0-0 \
    libglib2.0-0 \
    libnss3 \
    libnspr4 \
    libdbus-1-3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libdrm2 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libpango-1.0-0 \
    libcairo2 \
    chromium \
  && rm -rf /var/lib/apt/lists/*

# --- non-root user matching the host user --------------------------------
# The node base image already ships a uid/gid 1000 "node" user — rename and
# reuse it if it matches, create "pi" otherwise.
ARG USER_UID=1000
ARG USER_GID=1000
RUN set -e; \
  if getent group "${USER_GID}" >/dev/null; then \
    groupmod -n pi "$(getent group "${USER_GID}" | cut -d: -f1)"; \
  else \
    groupadd --gid "${USER_GID}" pi; \
  fi; \
  if getent passwd "${USER_UID}" >/dev/null; then \
    old="$(getent passwd "${USER_UID}" | cut -d: -f1)"; \
    if [ "$old" != "pi" ]; then usermod -l pi "$old"; fi; \
    usermod -g pi -d /home/pi -m -s /bin/bash pi; \
  else \
    useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --shell /bin/bash pi; \
  fi

# --- preinstall pi -------------------------------------------------------
ARG PI_VERSION=1.5.0
RUN npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}"

# --- preinstall vibeflow CLI (task board CLI used by workspace hooks) --------
# Provides the `vibeflow` (alias `vf`) command that .vibeflow-commander-hook
# agent prompts rely on (`vibeflow tasks ...`). Pinned like pi: reinstalling
# or upgrading inside a session only changes the running container.
ARG VIBEFLOW_VERSION=0.27.1
RUN npm install -g "@vibeflow-tools/cli@${VIBEFLOW_VERSION}"

# --- preinstall herdr (terminal runtime for coding agents) ----------------
# herdr runs every terminal in this container (see container/AGENTS.md) and
# keeps them alive across SSH disconnects and client restarts. Pinned like
# pi: `herdr update` inside a session only changes the running container.
# Installed pi-owned so that update can replace it at runtime.
ARG HERDR_VERSION=0.9.5
COPY container/install-herdr.sh /usr/local/bin/install-herdr
RUN chmod 0755 /usr/local/bin/install-herdr \
  && install-herdr "${HERDR_VERSION}" /home/pi/.local/bin \
  && chown -R pi:pi /home/pi/.local
ENV PATH="/home/pi/.local/bin:${PATH}"

# --- preinstalled pi extensions (packages) --------------------------------
# Declared in container/pi-extensions.txt (one `pi install` source per
# line); installed here so fresh volumes start with them and the npm cache
# is warm. The entrypoint re-syncs the same list at container boot, so
# lines added later are picked up on the next start. Pin versions in the
# list (npm:pkg@x.y.z) for reproducible builds.
COPY container/pi-extensions.txt /opt/pi-service/pi-extensions.txt
COPY container/pi-extensions-sync.sh /usr/local/bin/pi-extensions-sync
RUN chmod 0755 /usr/local/bin/pi-extensions-sync \
  && chmod 644 /opt/pi-service/pi-extensions.txt
USER pi
RUN /usr/local/bin/pi-extensions-sync
USER root

# --- pi-install helper + the only root path for the pi user --------------
# The helper validates package names, installs via apt, and records the
# packages in this Dockerfile (see container/AGENTS.md). Keep it root-owned.
COPY container/pi-install.sh /usr/local/bin/pi-install
RUN chmod 0755 /usr/local/bin/pi-install \
  && echo 'pi ALL=(root) NOPASSWD: /usr/local/bin/pi-install' > /etc/sudoers.d/pi-install \
  && chmod 0440 /etc/sudoers.d/pi-install

# --- entrypoint: herdr server + default model from compose env -----------
COPY container/pi-entrypoint.sh /usr/local/bin/pi-entrypoint
RUN chmod 0755 /usr/local/bin/pi-entrypoint

# --- pi wrapper: bare `pi` respects PI_DEFAULT_* (see pi-wrapper.sh) -----
# Installed as /home/pi/.local/bin/pi (first in PATH), shadowing the real
# /usr/local/bin/pi, which the wrapper execs by absolute path. Also kept at
# /opt/pi-service/pi-wrapper.sh so the entrypoint can (re)install it on
# every boot — host edits via the compose bind-mount take effect on restart
# even before the next rebuild bakes them in.
COPY container/pi-wrapper.sh /opt/pi-service/pi-wrapper.sh
RUN chmod 0755 /opt/pi-service/pi-wrapper.sh \
  && cp /opt/pi-service/pi-wrapper.sh /home/pi/.local/bin/pi \
  && chown pi:pi /home/pi/.local/bin/pi

# --- pi-worktree helper: one isolated git worktree per parallel agent ----
# Source lives at /opt/pi-service/pi-worktree.sh (bind-mounted from the
# host, see docker-compose.yml) and is (re)installed to PATH on every
# boot by the entrypoint, so host edits take effect on restart even before
# the next rebuild bakes them in. See container/AGENTS.md.
COPY container/pi-worktree.sh /opt/pi-service/pi-worktree.sh
RUN chmod 0755 /opt/pi-service/pi-worktree.sh \
  && cp /opt/pi-service/pi-worktree.sh /usr/local/bin/pi-worktree

# Pre-create the pi home dir so the named volume (see docker-compose.yml)
# inherits pi:pi ownership instead of root.
RUN mkdir -p /home/pi/.pi/agent \
  && chown -R pi:pi /home/pi/.pi

# --- GitHub CLI: persist the login across container recreations ---------
# Everything outside /home/pi/.pi/agent is container-local, but gh stores
# its credentials under ~/.config/gh. Symlink that into the pi-agent-home
# volume so `gh auth login` survives `docker compose down`. The entrypoint
# creates the target dir on a fresh volume.
# Same for herdr: its state (~/.config/herdr — config, workspace layout,
# session snapshots, logs) lives in the volume, so workspaces and agents
# come back after the container is recreated.
RUN mkdir -p /home/pi/.config \
  && ln -sfn /home/pi/.pi/agent/gh /home/pi/.config/gh \
  && ln -sfn /home/pi/.pi/agent/herdr /home/pi/.config/herdr \
  && chown -R pi:pi /home/pi/.config
# Use gh as the git credential helper for all hosts (system-wide), so git
# push/pull over HTTPS works with the gh login. `gh auth login` offers the
# same setup per-user, but ~/.gitconfig itself is container-local.
RUN git config --system credential.helper '!gh auth git-credential'

# --- image stamp (pi-run rebuilds when this no longer matches) -----------
ARG PI_STAMP=unstamped
LABEL pi.service.stamp="${PI_STAMP}"

USER pi
ENV HOME=/home/pi
WORKDIR /workspace

ENTRYPOINT ["pi-entrypoint"]
