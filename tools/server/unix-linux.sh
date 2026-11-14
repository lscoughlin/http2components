#!/bin/sh
# Copyright 2026 Liam Seamus Coughlin
# SPDX-License-Identifier: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
# Run the Unix socket suites and the full test targets on a Linux host.
#
# Usage:
#   sh tools/server/unix-linux.sh
#   DOCKER_CONTEXT=<context> sh tools/server/unix-linux.sh
#
# DOCKER_CONTEXT names the Docker context that runs the build (no default;
# set it in .env). The host must answer "linux x86_64". The script stages the tracked
# files in bin/unix-linux-stage, builds the toolchain stage of
# tools/server/container/Dockerfile, then builds
# tools/server/container/Dockerfile.unix on that context. The full output of
# the build goes to bin/unix-linux.log. The script prints the lines that
# report test counts and the lines that name the Unix tests.
#
# Exit status: 0 when every build step passes. 1 when the host is not
# Linux x86_64, when the staging holds a credentials file or a key file
# outside the test fixtures, or when a build step fails.

set -eu

: "${DOCKER_CONTEXT:?DOCKER_CONTEXT is not set (put it in .env)}"

info=$(docker -c "$DOCKER_CONTEXT" info --format '{{.OSType}} {{.Architecture}}') || {
  echo "unix-linux: docker -c $DOCKER_CONTEXT info failed" >&2
  exit 1
}
if [ "$info" != 'linux x86_64' ]; then
  echo "unix-linux: context $DOCKER_CONTEXT answers '$info', expected 'linux x86_64'" >&2
  exit 1
fi

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
mkdir -p bin
log=$root/bin/unix-linux.log
stage=$root/bin/unix-linux-stage
rm -rf "$stage"
mkdir "$stage"
trap 'rm -rf "$stage"' EXIT

# Stage the tracked files only.
git ls-files -z | tar --null -T - -cf - | tar -xf - -C "$stage"
if [ ! -f "$stage/Taskfile.yaml" ]; then
  echo "unix-linux: the staging holds no Taskfile.yaml; the staging failed" >&2
  exit 1
fi

# Refuse to build when the staging holds a credentials file.
credentials=$(find "$stage" -name .credentials)
if [ -n "$credentials" ]; then
  echo "unix-linux: refused: the staging holds a credentials file:" >&2
  printf '%s\n' "$credentials" >&2
  exit 1
fi

# Refuse to build when the staging holds a key file outside the test
# fixtures. The tracked test keys live in test/fixtures/ (the client
# certificates, the TLS integration security fixtures) and in
# test/tls/tlslib/fixtures/.
keys=$(find "$stage" -name '*.key' \
  ! -path "$stage/test/fixtures/*" \
  ! -path "$stage/test/tls/tlslib/fixtures/*")
if [ -n "$keys" ]; then
  echo "unix-linux: refused: the staging holds a key file outside the test fixtures:" >&2
  printf '%s\n' "$keys" >&2
  exit 1
fi

toolchain_tag=http2components-toolchain-amd64
image_tag=http2components-unix-linux

{
  echo "unix-linux: UTC $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "unix-linux: context $DOCKER_CONTEXT answers '$info'"
} > "$log"

# Build the toolchain stage of the shared Dockerfile. The stage is cached
# when its inputs did not change.
status=0
docker -c "$DOCKER_CONTEXT" build --progress=plain --target toolchain \
  -f "$stage/tools/server/container/Dockerfile" \
  -t "$toolchain_tag" "$stage" >> "$log" 2>&1 || status=$?

# Build the Unix run. --no-cache makes every suite run print its output.
if [ "$status" -eq 0 ]; then
  docker -c "$DOCKER_CONTEXT" build --progress=plain --no-cache \
    --build-arg TOOLCHAIN_IMAGE="$toolchain_tag" \
    -f "$root/tools/server/container/Dockerfile.unix" \
    -t "$image_tag" "$stage" >> "$log" 2>&1 || status=$?
fi

echo "unix-linux: log $log"
grep -E 'Number of run tests|Number of (errors|failures)|PASS [0-9]+ case|Test elapsed|Test run exceeded|Test runner (reported|terminated)|Test runner did not|Test start' "$log" || true

for name in TestPeerPidOfAConnectedPair TestPeerTextHasThePid TestPathOf103BytesBinds TestTlsOverUnix TestStopWithOpenConnection TestFileRemovedAfterStop; do
  if grep -F -q -- "$name" "$log"; then
    grep -F -- "$name" "$log"
  else
    echo "unix-linux: no line in the log names $name"
  fi
done

if [ "$status" -ne 0 ]; then
  echo "unix-linux: a build step failed with status $status; the end of the log follows" >&2
  tail -n 40 "$log" >&2
  exit 1
fi
echo "unix-linux: every Unix suite and test target passed"
