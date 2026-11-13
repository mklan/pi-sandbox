# Pi coding-agent sandbox image — multi-stage.
#
# Build from the repository root:  docker compose build  (or pi-run)
#
# Stages:
#   base    — Ubuntu LTS + everything every sandbox needs: general tooling
#             (git, gh, curl/jq/ripgrep/fd, ssh client, Chrome for browser
#             tests), Node.js (pi/vibeflow are Node apps, so the runtime
#             lives here too), Docker CLI/compose plugin, herdr, the pi and
#             vibeflow CLIs + preinstalled pi extensions, the pi user,
#             pi-install, entrypoint and helpers.
#   default — base alias (kept as the `pi-sandbox` build target for
#             backwards compatibility; adds nothing — Node.js already lives
#             in base because pi/vibeflow need it at runtime).
#   android — default + OpenJDK + Android SDK + Gradle + Kotlin: builds
#             Kotlin/Android apps (assembleDebug/lint/test, no emulator
#             system images — run the emulator on the host).
#
# Which sandbox runs is selected in pi-run (`pi-run --sandbox android`
# or PI_SANDBOX=android), which builds the matching target — see
# docker-compose.yml. The base stage is a build layer only; no service
# runs it directly (`docker build --target base` for inspection).
#
# pi runs as a non-root user whose uid/gid match the host user (build args
# USER_UID/USER_GID, default 1000), so files written into the mounted
# /workspace folders are owned by you instead of root.
#
# Self-extending image: inside a session the agent installs missing tools
# with `pi-install <pkg>` — that installs into the running container and
# records the package in the apt list of the base stage below, so it is
# baked into the image at the next build. The file is mounted into the
# running container at /opt/pi-service/Dockerfile (see
# docker-compose.yml); `pi-run` compares the PI_STAMP label against the
# image sources and rebuilds automatically before starting a new session.

# --- pinned versions (bump with pi-run upgrade-*) ------------------------
ARG UBUNTU_VERSION=24.04
ARG PI_VERSION=1.5.0
ARG VIBEFLOW_VERSION=0.27.1
ARG HERDR_VERSION=0.9.5
ARG NODE_VERSION=24.22.2
ARG DOCKER_VERSION=29.9.3
ARG COMPOSE_VERSION=v5.7.0
ARG DOCKER_GID=999
ARG KOTLIN_VERSION=2.1.0
ARG GRADLE_VERSION=8.10.2
ARG ANDROID_CMDLINE_TOOLS=11076708
ARG ANDROID_BUILD_TOOLS=34.0.0
ARG ANDROID_PLATFORM=android-34

# === base: Ubuntu + everything every sandbox needs =========================
FROM ubuntu:${UBUNTU_VERSION} AS base

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
    gh \
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
    xz-utils \
    zip \
  && rm -rf /var/lib/apt/lists/*

# --- Google Chrome (browser tests) ---------------------------------------
# Ubuntu ships no chromium .deb (the `chromium` package is a snap stub,
# and snapd does not run in this container), so install Chrome stable
# from Google — apt resolves its library dependencies automatically.
RUN set -e; \
  cd /tmp; \
  curl -fsSLO "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"; \
  apt-get update; \
  apt-get install -y --no-install-recommends ./google-chrome-stable_current_amd64.deb; \
  rm -f google-chrome-stable_current_amd64.deb; \
  rm -rf /var/lib/apt/lists/*; \
  google-chrome --version

# --- non-root user matching the host user --------------------------------
# Created fresh on this base (plain ubuntu ships no node user), so files
# written into the mounted /workspace folders are owned by you instead
# of root.
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

# --- Node.js (our main stack — and pi/vibeflow's runtime) ----------------
# From the official tarball, pinned via NODE_VERSION for reproducible
# builds; bump with `pi-run upgrade-node`. Installed system-wide so
# node/npm/npx work for root and pi alike (global npm packages land in
# /usr/local). Lives in base because the pi and vibeflow CLIs below are
# Node apps and need it at runtime.
ARG NODE_VERSION
RUN set -e; \
  arch="$(dpkg --print-architecture)"; \
  case "$arch" in amd64) node_arch=x64 ;; arm64) node_arch=arm64 ;; \
    *) echo "node: unsupported architecture: $arch" >&2; exit 1 ;; esac; \
  cd /tmp; \
  curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
  curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"; \
  grep "node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" SHASUMS256.txt | sha256sum -c -; \
  tar -xJf "node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" -C /usr/local --strip-components=1; \
  rm -f "node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" SHASUMS256.txt; \
  node --version && npm --version

# --- Docker CLI + compose plugin (host daemon via socket) ----------------
# No dockerd inside: a privileged DinD daemon would void the sandbox
# hardening (see README.md). Instead the CLI talks to the host daemon
# through a bind-mounted /var/run/docker.sock (opt-in per machine, see
# docker-compose.yml) — the devcontainer-standard docker-outside-of-docker
# setup, enough for agents to build images and run e2e stacks.
# Pinned like everything else; bump with `pi-run upgrade-docker` /
# `pi-run upgrade-compose`.
ARG DOCKER_VERSION
ARG COMPOSE_VERSION
ARG DOCKER_GID
RUN set -e; \
  arch="$(dpkg --print-architecture)"; \
  case "$arch" in amd64) docker_arch=x86_64 ;; arm64) docker_arch=aarch64 ;; \
    *) echo "docker: unsupported architecture: $arch" >&2; exit 1 ;; esac; \
  cd /tmp; \
  curl -fsSLO "https://download.docker.com/linux/static/stable/${docker_arch}/docker-${DOCKER_VERSION}.tgz"; \
  tar -xzf "docker-${DOCKER_VERSION}.tgz" -C /tmp; \
  mv /tmp/docker/docker /usr/local/bin/docker; \
  rm -rf "docker-${DOCKER_VERSION}.tgz" /tmp/docker; \
  mkdir -p /usr/local/lib/docker/cli-plugins; \
  curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${docker_arch}" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose; \
  chmod 0755 /usr/local/bin/docker /usr/local/lib/docker/cli-plugins/docker-compose; \
  docker --version && docker compose version; \
  if getent group docker >/dev/null; then echo "docker group exists"; \
  elif getent group "${DOCKER_GID}" >/dev/null; then \
    echo "ERROR: GID ${DOCKER_GID} is taken by another group — rebuild with --build-arg DOCKER_GID=<host docker gid>" >&2; exit 1; \
  else groupadd --gid "${DOCKER_GID}" docker; fi; \
  usermod -aG docker pi

# --- preinstall herdr (terminal runtime for coding agents) ----------------
# herdr runs every terminal in this container (see container/AGENTS.md) and
# keeps them alive across SSH disconnects and client restarts. Pinned like
# pi: `herdr update` inside a session only changes the running container.
# Installed pi-owned so that update can replace it at runtime.
ARG HERDR_VERSION
COPY container/install-herdr.sh /usr/local/bin/install-herdr
RUN chmod 0755 /usr/local/bin/install-herdr \
  && mkdir -p /home/pi/.local/bin \
  && install-herdr "${HERDR_VERSION}" /home/pi/.local/bin \
  && chown -R pi:pi /home/pi/.local
ENV PATH="/home/pi/.local/bin:${PATH}"

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

# --- pi-hostpath helper: sandbox path -> host path for docker mounts ----
# The host daemon resolves bind mounts on the host, where /workspace/...
# does not exist. Same overlay mechanism as above (see
# docker-compose.yml); entrypoint reinstalls host edits on every boot.
COPY container/pi-hostpath.sh /opt/pi-service/pi-hostpath.sh
RUN chmod 0755 /opt/pi-service/pi-hostpath.sh \
  && cp /opt/pi-service/pi-hostpath.sh /usr/local/bin/pi-hostpath

# Pre-create the pi home dir so the named volume (see docker-compose.yml)
# inherits pi:pi ownership instead of root.
RUN mkdir -p /home/pi/.pi/agent \
  && chown -R pi:pi /home/pi/.pi

# Pre-create ~/.ssh pi-owned so bind-mounting known_hosts (a single file,
# see docker-compose.yml) does not leave a root-owned parent dir behind —
# ssh refuses to use a ~/.ssh it does not own.
RUN mkdir -p /home/pi/.ssh \
  && chown pi:pi /home/pi/.ssh \
  && chmod 700 /home/pi/.ssh

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

# --- preinstall pi -------------------------------------------------------
# Node app, so Node.js above is its runtime. Pinned like everything else.
ARG PI_VERSION
RUN npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}"

# --- preinstall vibeflow CLI (task board CLI used by workspace hooks) --------
# Provides the `vibeflow` (alias `vf`) command that .vibeflow-commander-hook
# agent prompts rely on (`vibeflow tasks ...`). Pinned like pi: reinstalling
# or upgrading inside a session only changes the running container.
ARG VIBEFLOW_VERSION
RUN npm install -g "@vibeflow-tools/cli@${VIBEFLOW_VERSION}"

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

# === default: base alias (adds nothing) ===================================
# Kept as the `pi-sandbox` build target so existing compose files, pi-run
# and docs keep working. Node.js, Docker CLI, pi/vibeflow and extensions
# all live in base now (pi/vibeflow are Node apps, so the runtime belongs
# there too); this stage exists only as a named alias for the daily driver.
FROM base AS default

# --- image stamp (pi-run rebuilds when this no longer matches) -----------
ARG PI_STAMP=unstamped
LABEL pi.service.stamp="${PI_STAMP}"

USER pi
ENV HOME=/home/pi
WORKDIR /workspace

ENTRYPOINT ["pi-entrypoint"]

# === android: default + JDK + Android SDK + Gradle + Kotlin ==============
# Builds Kotlin/Android apps: `gradle assembleDebug`, lint and unit tests.
# Ships the SDK (cmdline-tools, platform-tools, one platform + build-tools)
# so no large download happens on first use; extend with sdkmanager as pi
# (the SDK dir is pi-owned). No emulator system images — they are GBs and
# need KVM; run the emulator on the host and `adb` into it from here.
FROM default AS android
USER root

# --- OpenJDK (Gradle and the Android toolchain run on Java) --------------
# JDK 17: what AGP 8.x + Gradle 8.x require. Bump together with the
# Gradle/Android pins below.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    openjdk-17-jdk-headless \
  && rm -rf /var/lib/apt/lists/* \
  && java -version
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

# --- Android SDK ----------------------------------------------------------
# Pinned cmdline-tools; the platform + build-tools come via sdkmanager so
# the exact revisions stay reproducible. Licences are pre-accepted.
ARG ANDROID_CMDLINE_TOOLS
ARG ANDROID_BUILD_TOOLS
ARG ANDROID_PLATFORM
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH="/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:${PATH}"
RUN set -e; \
  mkdir -p /opt/android-sdk/cmdline-tools; \
  cd /tmp; \
  curl -fsSLO "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS}_latest.zip"; \
  unzip -q "commandlinetools-linux-${ANDROID_CMDLINE_TOOLS}_latest.zip" -d /opt/android-sdk/cmdline-tools; \
  mv /opt/android-sdk/cmdline-tools/cmdline-tools /opt/android-sdk/cmdline-tools/latest; \
  rm -f "commandlinetools-linux-${ANDROID_CMDLINE_TOOLS}_latest.zip"; \
  yes | sdkmanager --licenses > /dev/null; \
  sdkmanager "platform-tools" "platforms;${ANDROID_PLATFORM}" "build-tools;${ANDROID_BUILD_TOOLS}"; \
  sdkmanager --list_installed; \
  chown -R pi:pi /opt/android-sdk

# --- Gradle (Android builds run through the Gradle wrapper, but a pinned
# --- system Gradle is handy for inspection and non-wrapper projects) -----
ARG GRADLE_VERSION
ENV PATH="/opt/gradle/bin:${PATH}"
RUN set -e; \
  cd /tmp; \
  curl -fsSLO "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip"; \
  mkdir -p /opt/gradle; \
  unzip -q "gradle-${GRADLE_VERSION}-bin.zip" -d /tmp; \
  cp -r "/tmp/gradle-${GRADLE_VERSION}/." /opt/gradle/; \
  rm -rf "/tmp/gradle-${GRADLE_VERSION}" "gradle-${GRADLE_VERSION}-bin.zip"; \
  gradle --version

# --- Kotlin compiler ------------------------------------------------------
ARG KOTLIN_VERSION
ENV PATH="/opt/kotlin/bin:${PATH}"
RUN set -e; \
  cd /tmp; \
  curl -fsSLO "https://github.com/JetBrains/kotlin/releases/download/v${KOTLIN_VERSION}/kotlin-compiler-${KOTLIN_VERSION}.zip"; \
  mkdir -p /opt/kotlin; \
  unzip -q "kotlin-compiler-${KOTLIN_VERSION}.zip" -d /opt/kotlin-tmp; \
  cp -r /opt/kotlin-tmp/kotlinc/. /opt/kotlin/; \
  rm -rf /opt/kotlin-tmp "kotlin-compiler-${KOTLIN_VERSION}.zip"; \
  kotlinc -version

# --- image stamp (same sources as default; per-image label) --------------
ARG PI_STAMP=unstamped
LABEL pi.service.stamp="${PI_STAMP}"

USER pi
ENV HOME=/home/pi
WORKDIR /workspace

ENTRYPOINT ["pi-entrypoint"]
