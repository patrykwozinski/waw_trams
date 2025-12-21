# Dockerfile for Fly.io deployment
# Based on Phoenix 1.8 recommended setup

ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.1.2
ARG DEBIAN_VERSION=bookworm-20241016-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# ==============================================================================
# BUILD STAGE
# ==============================================================================
FROM ${BUILDER_IMAGE} AS builder

# Install build dependencies including Node.js for assets
RUN apt-get update -y && apt-get install -y build-essential git curl \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Set build environment
ENV MIX_ENV="prod"

# Install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Copy compile-time config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Install npm dependencies
COPY assets/package.json assets/package-lock.json ./assets/
RUN cd assets && npm ci

# Copy all source files
COPY priv priv
COPY lib lib
COPY assets assets
COPY config/runtime.exs config/

# Compile the application FIRST (generates colocated hooks)
RUN mix compile

# THEN compile assets (needs colocated hooks from mix compile)
RUN mix assets.deploy

# Build release
RUN mix release

# ==============================================================================
# RUNNER STAGE
# ==============================================================================
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

# Set runner ENV
ENV MIX_ENV="prod"

# Copy release from builder
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/waw_trams ./

USER nobody

# Create migration script for Fly.io release_command
RUN echo '#!/bin/sh\n/app/bin/waw_trams eval "WawTrams.Release.migrate"' > /app/bin/migrate && \
    chmod +x /app/bin/migrate

CMD ["/app/bin/waw_trams"]
