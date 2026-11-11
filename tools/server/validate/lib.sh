#!/usr/bin/env sh
#
# Start the validation server on a free port and print the port.
#
# The caller sources this file.  The function `start_interop_server` starts
# the server example program with port zero, reads the port the program printed,
# and leaves the process id in the variable INTEROP_PID.  The function
# `stop_interop_server` ends the program.  The program stops when its
# standard input closes, so the shell holds a pipe open to it.

INTEROP_PID=''
EXAMPLE_PID=''
EXAMPLE_OUT=''
EXAMPLE_PORT=''
PIPELINE_STOP_RESULT=''

# Wait for an owned pipeline subshell to finish. Zombies are complete here;
# the caller reaps them with wait.
pipeline_running() {
  pipeline_state=$(ps -o stat= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//')
  case "$pipeline_state" in
    ''|Z*) return 1 ;;
    *) return 0 ;;
  esac
}

wait_pipeline() {
  wait_pipeline_pid=$1
  wait_pipeline_count=$2
  wait_pipeline_index=0
  while [ "$wait_pipeline_index" -lt "$wait_pipeline_count" ]; do
    if ! pipeline_running "$wait_pipeline_pid"; then
      return 0
    fi
    sleep 0.1
    wait_pipeline_index=$((wait_pipeline_index + 1))
  done
  ! pipeline_running "$wait_pipeline_pid"
}

signal_pipeline_children() {
  signal_pipeline_pid=$1
  signal_pipeline_name=$2
  signal_pipeline_list=$3
  signal_pipeline_current=" $(pgrep -P "$signal_pipeline_pid" 2>/dev/null \
    | tr '\n' ' ' || true) "
  for signal_pipeline_child in $signal_pipeline_list; do
    case "$signal_pipeline_current" in
      *" $signal_pipeline_child "*)
        kill -"$signal_pipeline_name" "$signal_pipeline_child" 2>/dev/null || true ;;
    esac
  done
}

# Stop the owned input holder first. Then let its server consume EOF and
# let the pipeline shell reap both children. Signals are a bounded fallback.
stop_owned_pipeline() {
  stop_pipeline_pid=$1
  [ -n "$stop_pipeline_pid" ] || return 0
  PIPELINE_STOP_RESULT='graceful-eof'
  stop_pipeline_children=$(pgrep -P "$stop_pipeline_pid" 2>/dev/null || true)
  stop_pipeline_holders=''
  for stop_pipeline_child in $stop_pipeline_children; do
    stop_pipeline_comm=$(ps -o comm= -p "$stop_pipeline_child" 2>/dev/null \
      | sed 's/^[[:space:]]*//')
    case "${stop_pipeline_comm##*/}" in
      sleep) stop_pipeline_holders="$stop_pipeline_holders $stop_pipeline_child" ;;
    esac
  done
  signal_pipeline_children "$stop_pipeline_pid" TERM "$stop_pipeline_holders"
  if ! wait_pipeline "$stop_pipeline_pid" 50; then
    PIPELINE_STOP_RESULT='fallback-term'
    signal_pipeline_children "$stop_pipeline_pid" TERM "$stop_pipeline_children"
    if ! wait_pipeline "$stop_pipeline_pid" 20; then
      PIPELINE_STOP_RESULT='fallback-kill'
      signal_pipeline_children "$stop_pipeline_pid" KILL "$stop_pipeline_children"
      if ! wait_pipeline "$stop_pipeline_pid" 20; then
        kill -TERM "$stop_pipeline_pid" 2>/dev/null || true
        if ! wait_pipeline "$stop_pipeline_pid" 10; then
          kill -KILL "$stop_pipeline_pid" 2>/dev/null || true
        fi
      fi
    fi
  fi
  wait "$stop_pipeline_pid" 2>/dev/null || true
}

# start_interop_server [binary] [extra args...]
# Start the server and set INTEROP_PID and INTEROP_PORT.
# A missing binary is not an error here; the caller checks the result.
start_interop_server() {
  interop_bin="${1:-${SERVER_BIN:-bin}/interop_server}"
  shift 2>/dev/null || true
  if [ ! -x "$interop_bin" ]; then
    return 1
  fi
  interop_out="${TMPDIR:-/tmp}/http2_interop_out.$$"
  # a long sleep holds the standard input of the server open; the pipe ends
  # when the sleep ends or when the process group is killed
  ( sleep 3600 | "$interop_bin" 0 "$@" >"$interop_out" 2>"${INTEROP_ERR:-/dev/null}" ) &
  INTEROP_PID=$!
  # wait for the port line, at most ten seconds
  i=0
  INTEROP_PORT=''
  while [ "$i" -lt 100 ]; do
    if [ -s "$interop_out" ]; then
      INTEROP_PORT=$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$interop_out" | head -1)
      if [ -n "$INTEROP_PORT" ]; then
        break
      fi
    fi
    i=$((i + 1))
    sleep 0.1
  done
  if [ -z "$INTEROP_PORT" ]; then
    stop_interop_server
    return 1
  fi
  return 0
}

# ensure_validation_certificate
# Create the self-signed certificate that the TLS checks use, when the pair
# is absent.  The subject and the subject alternative name are those of the
# sibling repository, so the same name works in both.  The function echoes
# the certificate directory on success and returns 1 on a missing openssl.
ensure_validation_certificate() {
  cert_dir="${1:-$root/test/fixtures/server/certs}"
  if [ -f "$cert_dir/localhost.crt" ] && [ -f "$cert_dir/localhost.key" ]; then
    echo "$cert_dir"
    return 0
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    return 1
  fi
  mkdir -p "$cert_dir" || return 1
  openssl req -x509 -newkey rsa:2048 \
    -keyout "$cert_dir/localhost.key" -out "$cert_dir/localhost.crt" \
    -days 3650 -nodes -subj '/CN=localhost' \
    -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' >/dev/null 2>&1 || return 1
  echo "$cert_dir"
  return 0
}

# stop_interop_server
# End the server and its pipe holder.  A call with no live process is safe.
# The server writes to a pipe whose write end a `sleep` holds, and both are
# children of the subshell that runs the pipeline.  Ending the subshell alone
# leaves the two children alive, so the caller waits on an open pipe for the
# whole sleep.  Each child ends first, and the subshell follows.
stop_interop_server() {
  if [ -n "$INTEROP_PID" ]; then
    stop_owned_pipeline "$INTEROP_PID"
    INTEROP_PID=''
    if [ -n "${INTEROP_LOG:-}" ] && [ -f "$interop_out" ]; then
      cat "$interop_out" >> "$INTEROP_LOG"
    fi
    rm -f "$interop_out"
  fi
}

# start_example_server [binary] [arguments...]
# Start one example server on its requested port and read its bound port.
start_example_server() {
  example_bin=${1:?server binary is required}
  shift
  if [ ! -x "$example_bin" ]; then
    return 1
  fi
  EXAMPLE_OUT="${TMPDIR:-/tmp}/http2_example_out.$$.${example_bin##*/}"
  ( sleep 3600 | "$example_bin" "$@" >"$EXAMPLE_OUT" 2>&1 ) &
  EXAMPLE_PID=$!
  i=0
  EXAMPLE_PORT=''
  while [ "$i" -lt 100 ]; do
    if [ -s "$EXAMPLE_OUT" ]; then
      EXAMPLE_PORT=$(sed -n 's#.*127\.0\.0\.1:\([0-9][0-9]*\)/.*#\1#p' "$EXAMPLE_OUT" | head -1)
      [ -n "$EXAMPLE_PORT" ] && return 0
    fi
    i=$((i + 1))
    sleep 0.1
  done
  stop_example_server
  return 1
}

# Stop only the example server started by start_example_server.
stop_example_server() {
  if [ -n "$EXAMPLE_PID" ]; then
    stop_owned_pipeline "$EXAMPLE_PID"
    EXAMPLE_PID=''
  fi
  if [ -n "${EXAMPLE_LOG:-}" ] && [ -n "$EXAMPLE_OUT" ] && [ -f "$EXAMPLE_OUT" ]; then
    cat "$EXAMPLE_OUT" >> "$EXAMPLE_LOG"
  fi
  [ -n "$EXAMPLE_OUT" ] && rm -f "$EXAMPLE_OUT"
  EXAMPLE_OUT=''
  EXAMPLE_PORT=''
}
