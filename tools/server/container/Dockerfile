# Copyright 2026 Liam Seamus Coughlin
# SPDX-License-Identifier: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
# Build and check http2components on Linux amd64 in two stages.
#
#   docker build --progress=plain -f tools/server/container/Dockerfile \
#     -t http2components-amd64 .
#
# Stage "toolchain" holds every tool and every dependency. It does not read the
# project sources, so Docker keeps its layers in the cache until a build
# argument changes. Stage "build" copies the sources, checks out every pinned
# dependency, and builds the library, packages, examples, and unit-test suites.
#
# This target builds the merged source tree. It does not run the load, abuse,
# or conformance gates.

# ---------------------------------------------------------------------------
# Stage 1: the toolchain
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS toolchain

# Free Pascal 3.2.4 has no distribution package and no upstream binary
# archive for Linux. The stage builds the release candidate that the macOS
# development machine uses, from the upstream tag. The Ubuntu package
# (version 3.2.2) is the bootstrap compiler only.
ARG FPC_TAG=release_3_2_4_rc2
# The mORMot2 revision is the pin of NOTICE and of Taskfile.yaml.
ARG MORMOT_REV=b2b195da1e0580058672a88620ef71bb47283eb1
ARG FPC_PREFIX=/opt/fpc
ARG MORMOT_DIR=/opt/mormot2
ARG H2SPEC_VERSION=2.6.0
ARG H2SPEC_SHA256=157ee0de702e01ad40e752dbf074b366027e550c8e7504f9450da2809e279318

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git make binutils gcc libc6-dev \
      fpc openssl libssl3t64 libssl-dev \
      python3 python3-yaml python3-h2 python3-wsproto \
      golang-go nghttp2-client \
 && rm -rf /var/lib/apt/lists/*

# Pin the HTTP/2 conformance tool by both release and archive digest.
RUN curl --fail --location --silent --show-error \
      "https://github.com/summerwind/h2spec/releases/download/v${H2SPEC_VERSION}/h2spec_linux_amd64.tar.gz" \
      -o /tmp/h2spec.tar.gz \
 && echo "${H2SPEC_SHA256}  /tmp/h2spec.tar.gz" | sha256sum --check --status \
 && tar -xzf /tmp/h2spec.tar.gz -C /usr/local/bin h2spec \
 && chmod 0755 /usr/local/bin/h2spec \
 && rm /tmp/h2spec.tar.gz

# Build the compiler, the run-time library and the packages, then install them.
RUN git clone --depth 1 --branch "${FPC_TAG}" \
      https://gitlab.com/freepascal.org/fpc/source.git /usr/src/fpc \
 && cd /usr/src/fpc \
 && make all OPT="-O2" \
 && make install INSTALL_PREFIX="${FPC_PREFIX}" \
 && "${FPC_PREFIX}/lib/fpc/$(ls "${FPC_PREFIX}/lib/fpc" | head -n 1)/samplecfg" \
      "${FPC_PREFIX}/lib/fpc/$(ls "${FPC_PREFIX}/lib/fpc" | head -n 1)" /etc \
 && ln -sf "${FPC_PREFIX}/bin/fpc" /usr/local/bin/fpc \
 && rm -rf /usr/src/fpc

# Remove the bootstrap compiler, so that no build can use it by mistake. The
# purge also removes /etc/fpc.cfg, which the Ubuntu package owns, so the step
# writes the configuration of the new compiler again after the purge. The
# driver `fpc` looks for the compiler binary `ppcx64` on the search path, so
# the step links it too.
ENV PATH=${FPC_PREFIX}/bin:${PATH}
RUN ver="$(ls "${FPC_PREFIX}/lib/fpc" | head -n 1)" \
 && ln -sf "${FPC_PREFIX}/lib/fpc/${ver}/ppcx64" /usr/local/bin/ppcx64 \
 && apt-get purge -y 'fpc*' 'fp-*' \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/* \
 && "${FPC_PREFIX}/lib/fpc/${ver}/samplecfg" "${FPC_PREFIX}/lib/fpc/${ver}" /etc \
 && fpc -iV \
 && fpc -iW

# Install Lazarus after removing the bootstrap compiler. Restore the custom
# compiler configuration because Lazarus may install an FPC config of its own.
RUN apt-get update \
 && apt-get install -y --no-install-recommends lazarus \
 && rm -rf /var/lib/apt/lists/* \
 && ver="$(ls "${FPC_PREFIX}/lib/fpc" | head -n 1)" \
 && "${FPC_PREFIX}/lib/fpc/${ver}/samplecfg" "${FPC_PREFIX}/lib/fpc/${ver}" /etc \
 && fpc -iV \
 && lazbuild --version

# Fetch the pinned mORMot2 revision.
RUN git init "${MORMOT_DIR}" \
 && git -C "${MORMOT_DIR}" remote add origin https://github.com/synopse/mORMot2.git \
 && git -C "${MORMOT_DIR}" fetch --depth 1 origin "${MORMOT_REV}" \
 && git -C "${MORMOT_DIR}" checkout --detach FETCH_HEAD \
 && test "$(git -C "${MORMOT_DIR}" rev-parse HEAD)" = "${MORMOT_REV}"

# ---------------------------------------------------------------------------
# Stage 2: the build and the simple checks
# ---------------------------------------------------------------------------
FROM toolchain AS build

ARG FPC_PREFIX=/opt/fpc
ARG MORMOT_DIR=/opt/mormot2

# The Makefile reads these variables from the environment.
ENV MORMOT=${MORMOT_DIR}/src \
    OPENSSL_LIBPATH=/usr/lib/x86_64-linux-gnu

WORKDIR /src
COPY . .

# The pinned mORMot revision tracks the digest of its external static bundle.
# Verification fails closed if the upstream bundle does not match that digest.
RUN tools/validation/prepare-linux.sh "${MORMOT_DIR}"

# The unit directory depends on the compiler version, so the step reads it.
RUN set -e; \
    export FPC_UNITS="${FPC_PREFIX}/lib/fpc/$(fpc -iV)/units/$(fpc -iTP)-$(fpc -iTO)"; \
    echo "unit directory: ${FPC_UNITS}"; \
    make setup-deps setup-harness all examples test test-api test-integration \
      packages-check source-check docs-check version-check

CMD ["/bin/sh", "-c", "ls -l /src/bin"]
