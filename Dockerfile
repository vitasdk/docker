# syntax=docker/dockerfile:1

# The base is pinned by digest from the workflow. The decision to publish is
# taken by comparing that digest with the one recorded in the published image,
# so the build has to use the very digest it decided on, not whatever the tag
# points at a few minutes later.
ARG BASE_IMAGE=ubuntu:24.04

FROM ${BASE_IMAGE} AS host-tools

ARG DEBIAN_FRONTEND=noninteractive

# cmake comes from the distribution on purpose. CMake 4 removed compatibility
# with cmake_minimum_required below 3.5 and most Vita homebrew predates that,
# so tracking the newest release upstream would break the projects this image
# exists to build.
#
# fakeroot, bsdtar (libarchive-tools) and file are not conveniences: vita-makepkg
# ships inside the SDK and does not run without them.
RUN apt-get update && apt-get install -y --no-install-recommends \
        bzip2 \
        ca-certificates \
        cmake \
        curl \
        fakeroot \
        file \
        git \
        libarchive-tools \
        make \
        ninja-build \
        pkgconf \
        python3 \
        sudo \
        tar \
        wget \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# The user exists in every variant, not only in the non-root one, so that
# `--user vitasdk` works on the plain tag and so that vita-makepkg -- which
# refuses to run with EUID 0 -- has somewhere to run.
#
# UID 1000 is worth insisting on: it is what the first user of a desktop or of
# a CI runner gets, and it is what decides whether the files left in a bind
# mount belong to the person who ran the container. Ubuntu 24.04 ships its own
# `ubuntu` user there, so it has to go first.
RUN userdel --remove ubuntu 2>/dev/null || true; \
    useradd --create-home --uid 1000 --shell /bin/bash vitasdk \
    && printf 'vitasdk ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/vitasdk \
    && chmod 0440 /etc/sudoers.d/vitasdk

FROM host-tools AS core

ARG VITASDK_CHANNEL
ARG VDPM_RELEASE=v0.1.0-rc1

ENV VITASDK=/usr/local/vitasdk
ENV PATH=$VITASDK/bin:$PATH

# The image installs what a user installs: the bootstrap resolves the host
# archive from the signed channel manifest and verifies it. Nothing here knows
# about build artefacts or release tags.
#
# The ownership fix belongs to this RUN and not to a later one: a recursive
# chown in its own layer rewrites the metadata of every file and duplicates the
# whole SDK in the registry. Group 0 with g+rwX is what lets an arbitrary UID
# -- the one Kubernetes or OpenShift hands out -- both use and write the SDK,
# which is what `vdpm install` at runtime needs.
RUN set -eu; \
    : "${VITASDK_CHANNEL:?a channel is required}"; \
    cd /tmp; \
    base_url="https://github.com/vitasdk/vdpm/releases/download/${VDPM_RELEASE}"; \
    curl -fsSLO "$base_url/bootstrap-vitasdk.sh"; \
    curl -fsSLO "$base_url/SHA256SUMS"; \
    grep ' bootstrap-vitasdk\.sh$' SHA256SUMS | sha256sum -c -; \
    chmod +x bootstrap-vitasdk.sh; \
    VITASDK_CHANNEL="$VITASDK_CHANNEL" ./bootstrap-vitasdk.sh --install-dir "$VITASDK"; \
    vdpm refresh "$VITASDK_CHANNEL"; \
    rm -f bootstrap-vitasdk.sh SHA256SUMS; \
    chown -R vitasdk:0 "$VITASDK"; \
    chmod -R g+rwX "$VITASDK"

# Setgid so that anything created here keeps group 0 and stays writable by
# whoever the container runs as.
RUN install -d -o vitasdk -g 0 -m 2775 /workspace

WORKDIR /workspace
CMD ["/bin/bash"]

# The exact content of the image. The dated tag only records when it was
# published; what it contains is this.
ARG CHANNEL_SEQUENCE
ARG CHANNEL_MANIFEST_SHA256
ARG CORE_RELEASE
ARG PACKAGES_RELEASE
ARG BASE_DIGEST
LABEL org.opencontainers.image.title="VitaSDK" \
      org.opencontainers.image.source="https://github.com/vitasdk/docker" \
      org.opencontainers.image.base.digest="${BASE_DIGEST}" \
      org.vitasdk.channel="${VITASDK_CHANNEL}" \
      org.vitasdk.channel.sequence="${CHANNEL_SEQUENCE}" \
      org.vitasdk.channel.manifest.sha256="${CHANNEL_MANIFEST_SHA256}" \
      org.vitasdk.core.release="${CORE_RELEASE}" \
      org.vitasdk.packages.release="${PACKAGES_RELEASE}"

# The core and nothing else: no target packages, no host compiler. A base to
# build your own image on, not an environment to work in.
FROM core AS minimal
LABEL org.vitasdk.variant="minimal"

FROM core AS full

ARG DEBIAN_FRONTEND=noninteractive
ARG VITASDK_CHANNEL

# A host compiler, for projects that build a helper tool of their own during
# the build. It is the heaviest thing in the image and the one nobody can add
# once the container is already running.
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

USER vitasdk

# The whole catalogue of the series, read from the series' own database instead
# of from a hand-kept list -- there is no list here to drift.
#
# Installing as the user rather than as root is deliberate: the patched pacman
# drops ARCHIVE_EXTRACT_OWNER when it is not root, so the files come out owned
# by the caller instead of by whatever the package recorded.
#
# The group bits are then set on exactly the files the packages brought, and
# not with a recursive pass over $VITASDK: touching a file that belongs to an
# earlier layer copies it into this one, and a recursive chmod here would carry
# a second copy of the whole core -- 450 MB of nothing.
# Asked through vdpm rather than through pacman directly: the layout of the
# database and the flags that reach it are vdpm's business, not this image's.
#
# The catalogue is not installable as a whole, and that is why the hand-kept
# list in vdpm existed -- it was never a stale list, it was a conflict-free
# selection. Two pairs cannot coexist, for two different reasons:
#
#   vita-rss-libdl / vita-libdl   declare the conflict, so pacman refuses
#   curl / curl-mbedtls           declare nothing and collide file by file
#
# Which of each pair a fresh SDK gets is a property of the catalogue, not of
# this image. These two exclusions keep what the community image has always
# installed, and they belong in the recipes as a package group: the day there
# is one, this argument disappears.
ARG EXCLUDED_PACKAGES="vita-libdl curl-mbedtls"

RUN set -eu; \
    packages=$(vdpm search . | sed -n 's|^vita/\([^ ]*\).*|\1|p'); \
    for excluded in $EXCLUDED_PACKAGES; do \
        packages=$(printf '%s\n' $packages | grep -vx "$excluded"); \
    done; \
    [ -n "$packages" ] || { echo "the [vita] repository is empty" >&2; exit 1; }; \
    VDPM_NONINTERACTIVE=1 vdpm install $packages; \
    vdpm files $packages | awk 'NF == 2 { print $2 }' | xargs -r chmod g+rwX; \
    rm -rf "$VITASDK/var/cache/pacman/pkg"/*

# Root is the default of the plain tag: it is what derived Dockerfiles
# (`RUN apt-get install ...`) and the container jobs of most CI systems expect.
# The non-root tag is this same filesystem with USER changed.
USER root
LABEL org.vitasdk.variant="full"
