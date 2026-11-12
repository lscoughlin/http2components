#!/bin/sh
# SPDX-License-Identifier: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
# Copyright 2026 Liam Seamus Coughlin
#
# Run a server live gate: the TLS live program or the mutual TLS live program.
#
# Usage: live.sh <tls|mtls>
#
# The script builds the client, compiles the live program with the task
# compile:server:probe, makes a temporary test PKI with
# tools/server/certs/make_mtls_pki.sh, and runs the program with the PKI
# directory as its only argument. The PKI step has a 30 s limit. The program
# has a 180 s limit. A command that exceeds its limit gets SIGTERM and, 3 s
# later, SIGKILL, in its whole process group. A trap removes the temporary
# directory on exit and on a signal.
#
# Environment:
#   LIVE_OUT          Output directory bin/<target>/<profile>. The default is
#                     computed from FPC, TARGET, PROFILE and DEBUG, as the
#                     task files do.
#   OPENSSL_LIBPATH   The OpenSSL 3 library directory. The default is the
#                     platform default of the build.
#   LIVE_TIMEOUT      Seconds for the live program (default 180). The test of
#                     the script lowers this value. A gate run does not set it.
#
# The exit code is the exit code of the live program. It is 1 for a setup
# failure or a deadline.
set -u

kind=${1:-}
case $kind in
  tls) source=test/integration/server/tls/Http2.Server.TlsLive.pas ;;
  mtls) source=test/integration/server/mtls/Http2.Server.MtlsLive.pas ;;
  *) echo "Usage: live.sh <tls|mtls>" >&2; exit 2 ;;
esac

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
cd "$root" || exit 1

limit=${LIVE_TIMEOUT:-180}
tmp=
child=
watchdog=
mark=

kill_group() {
  # $1 is a process id. Under job control it is also its process group id.
  kill -TERM -- "-$1" 2>/dev/null || kill -TERM "$1" 2>/dev/null
}

cleanup() {
  if [ -n "$child" ]; then
    kill_group "$child"
    kill -KILL -- "-$child" 2>/dev/null
    child=
  fi
  if [ -n "$watchdog" ]; then
    kill -TERM -- "-$watchdog" 2>/dev/null
    watchdog=
  fi
  if [ -n "$tmp" ] && [ -d "$tmp" ]; then
    rm -rf "$tmp"
  fi
  tmp=
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# run_limited <seconds> <command> [argument...]
# Run the command in its own process group. Stop the group at the deadline.
run_limited() {
  seconds=$1
  shift
  mark=$tmp/.deadline
  rm -f "$mark"
  echo "+ $*"
  set -m
  "$@" &
  child=$!
  watchdog_target=$child
  (
    sleep "$seconds"
    : > "$mark"
    kill -TERM -- "-$watchdog_target" 2>/dev/null
    sleep 3
    kill -KILL -- "-$watchdog_target" 2>/dev/null
  ) &
  watchdog=$!
  set +m
  wait "$child"
  status=$?
  # Stop the watchdog and its sleep.
  kill -TERM -- "-$watchdog" 2>/dev/null || kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  watchdog=
  kill -KILL -- "-$child" 2>/dev/null
  child=
  if [ -e "$mark" ]; then
    rm -f "$mark"
    echo "Command exceeded its ${seconds}s deadline; process group stopped" >&2
    return 1
  fi
  return "$status"
}

# The OPENSSL_LIBPATH default and the Darwin PATH rule of open_ssl_env.
if [ -z "${OPENSSL_LIBPATH:-}" ]; then
  case $(uname -s) in
    Darwin)
      case $(uname -m) in
        arm64|aarch64) prefix=/opt/homebrew ;;
        *) prefix=/usr/local ;;
      esac
      OPENSSL_LIBPATH=$prefix/opt/openssl@3/lib
      export OPENSSL_LIBPATH ;;
    Linux)
      case $(uname -m) in
        x86_64) OPENSSL_LIBPATH=/usr/lib/x86_64-linux-gnu; export OPENSSL_LIBPATH ;;
        aarch64) OPENSSL_LIBPATH=/usr/lib/aarch64-linux-gnu; export OPENSSL_LIBPATH ;;
      esac ;;
  esac
fi
if [ "$(uname -s)" = Darwin ] && [ -x "${OPENSSL_LIBPATH:-}/../bin/openssl" ]; then
  PATH=$(cd "$OPENSSL_LIBPATH/../bin" && pwd):$PATH
  export PATH
fi

if [ -z "${LIVE_OUT:-}" ]; then
  fpc=${FPC:-fpc}
  if [ -n "${TARGET:-}" ]; then
    target=$TARGET
  else
    target=$("$fpc" -iTP)-$("$fpc" -iTO) || exit 1
  fi
  if [ -n "${PROFILE:-}" ]; then
    profile=$PROFILE
  elif [ -n "${DEBUG:-}" ]; then
    profile=debug
  else
    profile=default
  fi
  LIVE_OUT=$root/bin/$target/$profile
fi

stem=$(basename "$source" .pas)
binary=$LIVE_OUT/integration-test/programs/$stem

task build:client || exit 1
task compile:server:probe -- "$source" || exit 1
if [ ! -x "$binary" ]; then
  echo "The live program was not built: $binary" >&2
  exit 1
fi

pki_parent=$(dirname "$binary")/$kind-live-pki
mkdir -p "$pki_parent" || exit 1
tmp=$(mktemp -d "$pki_parent/pki-XXXXXX") || exit 1

run_limited 30 sh tools/server/certs/make_mtls_pki.sh "$tmp" || exit 1
run_limited "$limit" "$binary" "$tmp"
exit $?
