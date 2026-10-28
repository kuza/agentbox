# agentbox base image: tooling only.
# Claude Code itself is installed into the "ab-claude-tools" volume by run.sh,
# so frequent Claude Code releases don't require rebuilding this image.
FROM docker.io/library/node:24-trixie-slim

# make runs project Makefiles; gcc and libc6-dev give Go cgo, which
# `go test -race` needs (Go enables cgo only when it finds a C compiler).
# socat runs the AB_FORWARD sidecars (lib/forward.sh). Debian names fd
# "fdfind"; pi looks for "fd", and would try to download it.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git ca-certificates curl ripgrep fd-find less openssh-client python3 python3-venv \
      make gcc libc6-dev socat \
 && rm -rf /var/lib/apt/lists/* \
 && ln -s /usr/bin/fdfind /usr/local/bin/fd

# ---------------------------------------------------------------------------
# Python for development: uv plus preinstalled interpreters.
# The agent cannot download interpreters at runtime (no github.com), so the
# versions you need are baked in here.
#   UV_VERSION        pinned uv release
#   PYTHON_VERSIONS   space-separated, e.g. "3.11 3.12 3.13"; run.sh passes
#                     AB_PYTHON_VERSIONS from config.env
# Interpreters land in /opt/uv-python (read-only for the agent) with
# python3.X shims in /usr/local/bin. System python3 (Debian 13: 3.13) stays as is.
# pip leaves the /opt/uv and /opt/graphify venvs once they are installed:
# nothing uses it there afterwards. (The pip that ships inside the uv Python
# interpreters stays; it is what python3.X -m pip runs.)
# ---------------------------------------------------------------------------
ARG UV_VERSION=0.12.23
ARG PYTHON_VERSIONS="3.12 3.13 3.14"
ENV UV_PYTHON_INSTALL_DIR=/opt/uv-python \
    UV_PYTHON_BIN_DIR=/usr/local/bin
RUN python3 -m venv /opt/uv \
 && /opt/uv/bin/pip install --no-cache-dir "uv==${UV_VERSION}" \
 && /opt/uv/bin/pip uninstall -y -q pip \
 && ln -s /opt/uv/bin/uv /opt/uv/bin/uvx /usr/local/bin/ \
 && uv python install ${PYTHON_VERSIONS} \
 && chmod -R a+rX /opt/uv-python

# ---------------------------------------------------------------------------
# Go toolchain and golangci-lint, from the official release archives,
# verified against the published SHA-256 checksums.
#   GO_VERSION             "1.26.3" exact; "1.26" = latest stable 1.26.x at
#                          build time; empty = latest stable at build time
#   GOLANGCI_LINT_VERSION  e.g. "2.14.0"; empty = latest release at build time
# Empty (or a minor version) means AB_UPGRADE brings newer releases; pin to
# control it. The resolved versions are printed in the build log. run.sh
# passes AB_GO_VERSION and AB_GOLANGCI_LINT_VERSION from config.env.
# ---------------------------------------------------------------------------
ARG GO_VERSION="1.26"
ARG GOLANGCI_LINT_VERSION=""
RUN set -eu; \
    arch="$(dpkg --print-architecture)"; \
    curl -fsSL 'https://go.dev/dl/?mode=json&include=all' -o /tmp/go.json; \
    v="$(python3 -c "import json,sys; v=sys.argv[1]; rs=[r['version'][2:] for r in json.load(open('/tmp/go.json')) if r['stable']]; print(v if v.count('.')==2 else max((r for r in rs if not v or r.startswith(v+'.')), key=lambda r: tuple(map(int, r.split('.')))))" "$GO_VERSION")"; \
    f="go${v}.linux-${arch}.tar.gz"; \
    sha="$(python3 -c "import json,sys; f=sys.argv[1]; print(next(x['sha256'] for r in json.load(open('/tmp/go.json')) for x in r['files'] if x['filename']==f))" "$f")"; \
    curl -fsSL "https://go.dev/dl/$f" -o /tmp/go.tgz; \
    echo "$sha  /tmp/go.tgz" | sha256sum -c -; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm /tmp/go.tgz /tmp/go.json; \
    /usr/local/go/bin/go version
RUN set -eu; \
    arch="$(dpkg --print-architecture)"; \
    v="${GOLANGCI_LINT_VERSION:-$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/golangci/golangci-lint/releases/latest | sed 's#.*/v##')}"; \
    base="https://github.com/golangci/golangci-lint/releases/download/v${v}"; \
    f="golangci-lint-${v}-linux-${arch}.tar.gz"; \
    curl -fsSL "$base/$f" -o /tmp/gl.tgz; \
    curl -fsSL "$base/golangci-lint-${v}-checksums.txt" | grep " $f\$" | sed "s# $f# /tmp/gl.tgz#" | sha256sum -c -; \
    tar -xzf /tmp/gl.tgz -C /tmp; \
    install -m 0755 "/tmp/golangci-lint-${v}-linux-${arch}/golangci-lint" /usr/local/bin/; \
    rm -rf /tmp/gl.tgz "/tmp/golangci-lint-${v}-linux-${arch}"; \
    golangci-lint version

# ---------------------------------------------------------------------------
# graphify (https://github.com/Graphify-Labs/graphify): code knowledge graph CLI
# used by the /graphify skill. Own venv, independent of your project's Python.
# The PyPI package is "graphifyy" (double y).
#   GRAPHIFY_VERSION  pinned on purpose; bump deliberately and rebuild
#   GRAPHIFY_EXTRAS   optional extras, e.g. "[sql,terraform]"; empty = code only.
#                     run.sh passes AB_GRAPHIFY_EXTRAS from config.env
# Exposed as /usr/local/bin/graphify: graphify writes the path it was invoked
# with into Claude Code hooks, and this path can also exist on the host.
# ---------------------------------------------------------------------------
ARG GRAPHIFY_VERSION=0.9.79
ARG GRAPHIFY_EXTRAS=""
RUN python3 -m venv /opt/graphify \
 && /opt/graphify/bin/pip install --no-cache-dir "graphifyy${GRAPHIFY_EXTRAS}==${GRAPHIFY_VERSION}" \
 && /opt/graphify/bin/pip uninstall -y -q pip \
 && ln -s /opt/graphify/bin/graphify /usr/local/bin/graphify

# ---------------------------------------------------------------------------
# Trivy (https://trivy.dev), only with WITH_TRIVY=1 (run.sh passes it for
# AB_TRIVY=1 in config.env). The release archive is verified against the
# published checksums. Its vulnerability database is not baked in: run.sh
# keeps it current in the ab-trivy volume (lib/trivy.sh).
#   TRIVY_VERSION  pinned; bump deliberately and rebuild
# ---------------------------------------------------------------------------
ARG WITH_TRIVY=""
ARG TRIVY_VERSION=0.76.0
RUN set -eu; \
    if [ "$WITH_TRIVY" != 1 ]; then exit 0; fi; \
    case "$(dpkg --print-architecture)" in \
      amd64) a=64bit ;; arm64) a=ARM64 ;; *) echo "no Trivy build for this architecture" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}"; \
    f="trivy_${TRIVY_VERSION}_Linux-${a}.tar.gz"; \
    curl -fsSL "$base/$f" -o /tmp/trivy.tgz; \
    curl -fsSL "$base/trivy_${TRIVY_VERSION}_checksums.txt" | grep " $f\$" | sed "s# $f# /tmp/trivy.tgz#" | sha256sum -c -; \
    tar -xzf /tmp/trivy.tgz -C /usr/local/bin trivy; \
    rm /tmp/trivy.tgz; \
    trivy --version

# No telemetry and no self-updates: fewer hosts in the egress allowlist,
# and updates are handled outside the agent container.
#   UV_PYTHON_DOWNLOADS=never  use only the baked-in interpreters
#   UV_LINK_MODE=copy          the uv cache and the venvs live on volumes
#   GOTOOLCHAIN=local          never download another Go toolchain at runtime;
#                              a go.mod needing a newer Go fails clearly instead
# GOPATH stays at the default ~/go, i.e. in the ab-claude-home volume, so the module
# and build caches persist across sessions.
ENV PATH=/opt/claude/bin:/usr/local/go/bin:/home/node/go/bin:$PATH \
    GOTOOLCHAIN=local \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    DISABLE_AUTOUPDATER=1 \
    GRAPHIFY_QUERY_LOG_DISABLE=1 \
    UV_PYTHON_DOWNLOADS=never \
    UV_LINK_MODE=copy

USER node
WORKDIR /work
ENTRYPOINT ["/opt/claude/bin/claude"]
