# Linters for the languages used in these dotfiles (see scripts/setup-lint.sh).
# Each tool is run through scripts/lint-container.sh, so no host install is needed.
FROM python:3.12-slim-bookworm

ARG TARGETARCH
ARG HADOLINT_VERSION=2.15.1
ARG RUFF_VERSION=0.17.2
ARG LUACHECK_VERSION=1.2.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl shellcheck \
        lua5.4 liblua5.4-dev luarocks gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*

RUN luarocks --lua-version=5.4 install "luacheck" "${LUACHECK_VERSION}" \
    && apt-get purge -y gcc libc6-dev liblua5.4-dev \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

COPY luacheck-main.lua /usr/local/lib/luacheck-main.lua
COPY luacheck /usr/local/bin/luacheck
RUN chmod 0755 /usr/local/bin/luacheck

RUN pip install --no-cache-dir "ruff==${RUFF_VERSION}"

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) hadolint_arch=x86_64 ;; \
        arm64) hadolint_arch=arm64 ;; \
        *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/hadolint \
        "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-linux-${hadolint_arch}"; \
    chmod 0755 /usr/local/bin/hadolint; \
    apt-get purge -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
