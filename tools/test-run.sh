#!/bin/sh
# SPDX-License-Identifier: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
# Copyright 2026 Liam Seamus Coughlin
#
# Run a test program with a time limit. The script replaces run, run_suite
# and the PKI step of tools/build.py. It needs no timeout program and no
# Python. It works with a POSIX sh on macOS and on Linux.
#
# Usage:
#   test-run.sh suite [-t SECONDS] [-C DIRECTORY] [-p PKI_PARENT] BINARY
#   test-run.sh run   [-t SECONDS] [-C DIRECTORY] COMMAND [ARGUMENT...]
#
# suite  Run BINARY with --suite=$TEST_SUITE (or --all), --format=plain and
#        --sparse. The limit is -t, else $TEST_TIMEOUT, else 180. The run
#        fails when it reports no tests: the output needs a line
#        "Number of run tests: N" or a line "PASS N cases" with N above 0.
#        With -p, the script makes a temporary PKI directory under
#        PKI_PARENT with tools/server/certs/make_mtls_pki.sh (limit 30 s),
#        sets HTTP2_TEST_PKI to it for the run and removes it at the end.
# run    Run COMMAND. The limit is -t, else 180. There is no test count check.
#
# At the end of the limit the script sends TERM to the program and to all of
# its descendants. After 3 more seconds it sends KILL.
# Exit status: the status of the program; 128 plus the signal number when a
# signal stopped the program; 1 for a timeout, an empty suite or a bad option.

set -u

mode=${1:-}
case $mode in
  suite|run) shift ;;
  *) echo "usage: test-run.sh suite|run [-t SECONDS] [-C DIRECTORY] [-p PKI_PARENT] COMMAND..." >&2; exit 2 ;;
esac

limit=
cwd=
pki_parent=
while getopts t:C:p: opt; do
  case $opt in
    t) limit=$OPTARG ;;
    C) cwd=$OPTARG ;;
    p) pki_parent=$OPTARG ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -ge 1 ] || { echo "test-run.sh: no command" >&2; exit 2; }

script_dir=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$script_dir")

if [ -z "$limit" ]; then
  if [ "$mode" = suite ]; then limit=${TEST_TIMEOUT:-180}; else limit=180; fi
fi
case $limit in
  ''|*[!0-9]*) echo "TEST_TIMEOUT must be a positive number of seconds" >&2; exit 1 ;;
esac
if [ "$limit" -lt 1 ]; then
  echo "TEST_TIMEOUT must be a positive number of seconds" >&2; exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-run.XXXXXX") || exit 1
pki_dir=
wd_pid=
cleanup() {
  if [ -n "$wd_pid" ]; then kill_tree TERM "$wd_pid"; fi
  if [ -n "$pki_dir" ]; then rm -rf "$pki_dir"; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Print the pids of all descendants of the process $1, one for each line.
descendants() {
  ps -A -o pid= -o ppid= | awk -v root="$1" '
    { parent[$1] = $2 }
    END {
      found = root; n = 1
      while (n > 0) {
        n = 0
        for (p in parent)
          if (!(p in seen) && p != root) {
            q = parent[p]
            if (q == root || (q in seen)) { seen[p] = 1; print p; n++ }
          }
      }
    }'
}

# Send the signal $1 to the process $2 and to all of its descendants. The
# function sets tree to the list of pids that it signalled. A shell has no
# portable way to start a process group (set -m needs a terminal and setsid
# is not on macOS), so the script walks the process tree.
kill_tree() {
  tree="$(descendants "$2") $2"
  # shellcheck disable=SC2086
  kill -s "$1" $tree 2>/dev/null
  return 0
}

# Run "$@". Stop the program and its descendants after $limit seconds.
# Output of the program goes to the terminal and to $tmp/out. The function
# sets run_status (the program status) and timed_out (1 or 0).
run_limited() {
  : > "$tmp/out"
  mkfifo "$tmp/fifo" || return 1
  tee "$tmp/out" < "$tmp/fifo" &
  tee_pid=$!
  if [ -n "$cwd" ]; then
    ( cd "$cwd" && exec "$@" ) > "$tmp/fifo" 2>&1 &
  else
    "$@" > "$tmp/fifo" 2>&1 &
  fi
  child=$!
  (
    sleep "$limit"
    : > "$tmp/timeout"
    kill_tree TERM "$child"
    saved=$tree
    sleep 3
    # shellcheck disable=SC2086
    kill -s KILL $saved 2>/dev/null
    kill_tree KILL "$child"
  ) > /dev/null 2>&1 &
  wd_pid=$!
  wait "$child"
  run_status=$?
  kill_tree TERM "$wd_pid"
  wait "$wd_pid" 2>/dev/null
  wd_pid=
  wait "$tee_pid" 2>/dev/null
  rm -f "$tmp/fifo"
  timed_out=0
  if [ -e "$tmp/timeout" ]; then timed_out=1; fi
}

# Print "+ <command>" as build.py does.
echo_command() {
  printf '+ %s\n' "$*"
}

signal_status() {
  # $1 is a status above 128. Print the signal name and exit with it.
  _n=$(($1 - 128))
  _name=$(kill -l "$_n" 2>/dev/null)
  case $_name in SIG*) ;; *) _name=SIG$_name ;; esac
  printf 'Test runner terminated by %s\n' "$_name"
  exit "$1"
}

if [ "$mode" = run ]; then
  echo_command "$@"
  run_limited "$@"
  if [ "$timed_out" = 1 ]; then
    echo "Command exceeded its ${limit}s deadline; process group stopped" >&2
    exit 1
  fi
  exit "$run_status"
fi

# Mode suite.
binary=$1
shift
if [ -n "${TEST_SUITE:-}" ]; then
  suite_arg=--suite=$TEST_SUITE
else
  suite_arg=--all
fi

if [ -n "$pki_parent" ]; then
  mkdir -p "$pki_parent" || exit 1
  pki_dir=$(mktemp -d "$pki_parent/pki-XXXXXX") || exit 1
  ( cd "$root" && exec "$script_dir/test-run.sh" run -t 30 sh tools/server/certs/make_mtls_pki.sh "$pki_dir" ) || exit $?
  HTTP2_TEST_PKI=$pki_dir
  export HTTP2_TEST_PKI
fi

echo_command "$binary" "$suite_arg" --format=plain --sparse
echo "Test start (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ); limit: ${limit}s"
started=$(date +%s)
run_limited "$binary" "$suite_arg" --format=plain --sparse
elapsed=$(($(date +%s) - started))
if [ "$timed_out" = 1 ]; then
  echo "Test elapsed: ${elapsed}s (timeout)"
  echo "Test run exceeded TEST_TIMEOUT=${limit}s; process group stopped" >&2
  exit 1
fi
echo "Test elapsed: ${elapsed}s; child exit: $run_status"
if [ "$run_status" -ne 0 ]; then
  if [ "$run_status" -gt 128 ] && [ "$run_status" -lt 160 ]; then signal_status "$run_status"; fi
  exit "$run_status"
fi
run_tests=$(sed -n 's/.*Number of run tests:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$tmp/out" | head -n 1)
pass_cases=$(sed -n 's/^PASS[[:space:]][[:space:]]*\([0-9][0-9]*\)[[:space:]][[:space:]]*cases\{0,1\}[[:space:]]*$/\1/p' "$tmp/out" | head -n 1)
if [ "${run_tests:-0}" -gt 0 ] || [ "${pass_cases:-0}" -gt 0 ]; then
  exit 0
fi
echo "Test runner reported no registered tests; empty suite cannot pass" >&2
exit 1
