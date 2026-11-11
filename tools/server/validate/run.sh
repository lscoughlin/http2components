#!/usr/bin/env sh
#
# Run the external HTTP/2 conformance tools against the example server.
#
# The script starts the `interop_server` program from the server example output
# directory on a free port and runs each tool
# that is present.  A tool that is absent is reported as a skip with its
# name, because the report must state what ran and what did not.
#
# Every tool takes its input from /dev/null, so the script never stops on a
# terminal that stays open.
#
# Usage: run.sh [conformance|fast|tls-live|websocket|websocket:h2|sse|abuse]
#   `conformance` runs the full h2spec, nghttp, curl, load, TLS, WebSocket,
#   and SSE checks. `fast` runs the two short h2spec packages. An h2spec
#   package name can replace the gate name for one package run.

set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
FPC="${FPC:-fpc}"
if [ -z "${TARGET:-}" ]; then
  TARGET=$("$FPC" -iTP)-$("$FPC" -iTO)
fi
if [ -z "${PROFILE:-}" ]; then
  PROFILE=default
  [ -n "${DEBUG:-}" ] && PROFILE=debug
fi
SERVER_BIN="${SERVER_BIN:-$root/bin/$TARGET/$PROFILE/examples-server/programs}"
. "$here/lib.sh"

# The TLS checks load OpenSSL at run time through mORMot2.  The library
# directory of the development host is the Homebrew one, and a caller that
# names another directory in OPENSSL_LIBPATH keeps it.
if [ -z "${OPENSSL_LIBPATH:-}" ] && [ -d /opt/homebrew/opt/openssl@3/lib ]; then
  OPENSSL_LIBPATH=/opt/homebrew/opt/openssl@3/lib
  export OPENSSL_LIBPATH
fi

report_skip() {
  skip_count=$((skip_count + 1))
  echo "SKIP  $1: $2"
}

report_pass() {
  pass_count=$((pass_count + 1))
  echo "PASS  $1"
}

report_fail() {
  fail_count=$((fail_count + 1))
  echo "FAIL  $1"
  exit_code=1
}

exit_code=0
pass_count=0
fail_count=0
skip_count=0
package="${1:-http2}"
gate="$package"
work="$(mktemp -d "${TMPDIR:-/tmp}/http2-server-validate.XXXXXX")"
log_dir="${VALIDATION_LOG_DIR:-$root/bin/validation/logs}"
mkdir -p "$log_dir"
run_id="$(date +%Y%m%dT%H%M%S)-$$"
safe_gate=$(echo "$gate" | tr '/:' '--')
safe_package=$(echo "$package" | tr '/:' '--')
run_started=$(date +%s)
cleanup() {
  status=$?
  trap - EXIT
  stop_example_server
  stop_interop_server
  rm -rf "$work"
  elapsed=$(( $(date +%s) - run_started ))
  echo "SUMMARY gate=$gate pass=$pass_count fail=$fail_count skip=$skip_count runtime=${elapsed}s exit=$status"
  echo "VALIDATION_LOG_DIR=$log_dir run=$run_id"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "$gate" in
  fast)
    if ! start_interop_server "$SERVER_BIN/interop_server" no-http11; then
      echo "the example server did not report a port" >&2
      exit 2
    fi
    if command -v h2spec >/dev/null 2>&1; then
      for pkg in http2/4.2 http2/6.5; do
        pkg_log=$(echo "$pkg" | tr '/:' '--')
        if h2spec -h 127.0.0.1 -p "$INTEROP_PORT" "$pkg" </dev/null >"$log_dir/h2spec-$safe_gate-$run_id-$pkg_log.log" 2>&1; then
          report_pass "h2spec $pkg"
        else
          report_fail "h2spec $pkg (see $log_dir/h2spec-$safe_gate-$run_id-$pkg_log.log)"
        fi
      done
    else
      report_fail "h2spec is required for the fast server gate"
    fi
    exit "$exit_code"
    ;;
  websocket)
    if ! start_example_server "$SERVER_BIN/ws_echo" 127.0.0.1 0; then
      report_fail "WebSocket example server did not become ready"
    else
      if python3 "$here/ws_h1_client.py" 127.0.0.1 "$EXAMPLE_PORT"; then
        report_pass "HTTP/1.1 WebSocket echo (5 checks)"
      else
        report_fail "HTTP/1.1 WebSocket echo"
      fi
      if python3 "$here/../abuse/ws_abuse.py" 127.0.0.1 "$EXAMPLE_PORT"; then
        report_pass "HTTP/1.1 WebSocket abuse checks"
      else
        report_fail "HTTP/1.1 WebSocket abuse checks"
      fi
    fi
    exit "$exit_code"
    ;;
  websocket:h2)
    ws_python="${WS_PYTHON:-python3}"
    if ! start_example_server "$SERVER_BIN/ws_echo" 127.0.0.1 0 big; then
      report_fail "WebSocket example server did not become ready"
    elif "$ws_python" -c 'import h2, wsproto' >/dev/null 2>&1; then
      if "$ws_python" "$here/ws_h2_client.py" 127.0.0.1 "$EXAMPLE_PORT" </dev/null; then
        report_pass "WebSocket echo over HTTP/2 with h2 and wsproto (32 checks)"
      else
        report_fail "WebSocket echo over HTTP/2 with h2 and wsproto"
      fi
    else
      report_fail "the Python packages h2 and wsproto are required for the HTTP/2 WebSocket gate"
    fi
    exit "$exit_code"
    ;;
  sse)
    if ! start_example_server "$SERVER_BIN/sse_replay" 127.0.0.1 0; then
      report_fail "SSE example server did not become ready"
    elif command -v curl >/dev/null 2>&1; then
      if sh "$here/sse_check.sh" 127.0.0.1 "$EXAMPLE_PORT"; then
        report_pass "SSE replay over HTTP/1.1 and HTTP/2"
      else
        report_fail "SSE replay over HTTP/1.1 and HTTP/2"
      fi
    else
      report_fail "curl is required for the server SSE gate"
    fi
    exit "$exit_code"
    ;;
  tls-live)
    if ! command -v openssl >/dev/null 2>&1; then
      report_fail "openssl is required for the server TLS gate"
      exit "$exit_code"
    fi
    cert_dir=$(ensure_validation_certificate "$work/certs") || {
      report_fail "the loopback certificate could not be created"
      exit "$exit_code"
    }
    if ! start_interop_server "$SERVER_BIN/interop_server" \
      --cert="$cert_dir/localhost.crt" --key="$cert_dir/localhost.key"; then
      report_fail "the TLS server did not report a port"
      exit "$exit_code"
    fi
    tls_port=$INTEROP_PORT
    alpn=$(echo | openssl s_client -connect "127.0.0.1:$tls_port" -alpn h2 2>/dev/null \
      | sed -n 's/^ *ALPN protocol: *//p' | head -1)
    if [ "$alpn" = h2 ]; then
      report_pass "openssl s_client negotiates ALPN h2"
    else
      report_fail "openssl s_client ALPN result ($alpn)"
    fi
    if command -v curl >/dev/null 2>&1; then
      tbody1=$(curl -sk -m 10 --http1.1 "https://127.0.0.1:$tls_port/" </dev/null)
      tbody2=$(curl -sk -m 10 --http2 "https://127.0.0.1:$tls_port/" </dev/null)
      if [ -n "$tbody1" ] && [ "$tbody1" = "$tbody2" ]; then
        report_pass "curl --http1.1 and --http2 give the same body (TLS)"
      else
        report_fail "curl --http1.1 and --http2 differ over TLS"
      fi
    else
      report_fail "curl is required for the server TLS gate"
    fi
    stop_interop_server
    if command -v curl >/dev/null 2>&1 &&
       start_interop_server "$SERVER_BIN/interop_server" no-http11 \
         --cert="$cert_dir/localhost.crt" --key="$cert_dir/localhost.key"; then
      if curl -sk -m 10 --http1.1 "https://127.0.0.1:$INTEROP_PORT/" </dev/null >/dev/null 2>&1; then
        report_fail "TLS with the fallback off still served HTTP/1.1"
      elif curl -sk -m 10 --http2 "https://127.0.0.1:$INTEROP_PORT/" </dev/null >/dev/null 2>&1; then
        report_pass "TLS with the fallback off refuses HTTP/1.1 and serves h2"
      else
        report_fail "TLS with the fallback off refused h2 too"
      fi
    elif command -v curl >/dev/null 2>&1; then
      report_fail "the TLS server with the fallback off did not start"
    fi
    exit "$exit_code"
    ;;
  abuse)
    abuse_server_log="$log_dir/abuse-strict-server-$run_id.log"
    abuse_peer_log="$log_dir/abuse-strict-peer-$run_id.log"
    : > "$abuse_server_log"
    : > "$abuse_peer_log"
    INTEROP_ERR=$abuse_server_log
    INTEROP_LOG=$abuse_server_log
    export INTEROP_ERR INTEROP_LOG
    if ! start_interop_server "$SERVER_BIN/interop_server" strict; then
      report_fail "strict example server did not become ready"
    else
      if python3 "$here/../abuse/abuse.py" 127.0.0.1 "$INTEROP_PORT" \
        >"$abuse_peer_log" 2>&1; then
        report_pass "HTTP/2 abuse checks"
      else
        report_fail "HTTP/2 abuse checks"
      fi
      stop_interop_server
    fi
    echo "--- strict server output: $abuse_server_log ---"
    cat "$abuse_server_log"
    echo "--- HTTP/2 abuse peer output: $abuse_peer_log ---"
    cat "$abuse_peer_log"
    unset INTEROP_ERR INTEROP_LOG
    if start_example_server "$SERVER_BIN/ws_echo" 127.0.0.1 0; then
      if python3 "$here/../abuse/ws_abuse.py" 127.0.0.1 "$EXAMPLE_PORT"; then
        report_pass "HTTP/1.1 WebSocket abuse checks"
      else
        report_fail "HTTP/1.1 WebSocket abuse checks"
      fi
    else
      report_fail "WebSocket example server did not become ready"
    fi
    exit "$exit_code"
    ;;
  conformance)
    package=http2
    ;;
esac

if [ ! -x "$SERVER_BIN/interop_server" ]; then
  echo "the example server is absent; run the build first: $SERVER_BIN/interop_server"
  exit 2
fi

start_interop_server "$SERVER_BIN/interop_server" no-http11 || {
  echo "the example server did not report a port"
  exit 2
}
echo "the example server listens on port $INTEROP_PORT"
# --- h2spec ---
if command -v h2spec >/dev/null 2>&1; then
  if [ "$package" = "fast" ]; then
    for pkg in http2/4.2 http2/6.5; do
      pkg_log=$(echo "$pkg" | tr '/:' '--')
      if h2spec -h 127.0.0.1 -p "$INTEROP_PORT" "$pkg" </dev/null >"$log_dir/h2spec-$safe_gate-$run_id-$pkg_log.log" 2>&1; then
        report_pass "h2spec $pkg"
      else
        report_fail "h2spec $pkg (see $log_dir/h2spec-$safe_gate-$run_id-$pkg_log.log)"
      fi
    done
  elif [ "$gate" != conformance ]; then
    if h2spec -h 127.0.0.1 -p "$INTEROP_PORT" "$package" </dev/null >"$log_dir/h2spec-$safe_gate-$run_id-$safe_package.log" 2>&1; then
      report_pass "h2spec $package"
    else
      report_fail "h2spec $package (see $log_dir/h2spec-$safe_gate-$run_id-$safe_package.log)"
    fi
  fi
else
  report_fail "h2spec is required for server conformance"
fi

# A complete conformance run includes the HTTP/2 and HPACK packages.
if [ "$gate" = conformance ]; then
  if command -v h2spec >/dev/null 2>&1; then
    for pkg in http2 hpack; do
      h2spec_log="$log_dir/h2spec-$safe_gate-$run_id-$pkg.log"
      if h2spec -h 127.0.0.1 -p "$INTEROP_PORT" "$pkg" </dev/null >"$h2spec_log" 2>&1; then
        report_pass "h2spec $pkg"
      else
        report_fail "h2spec $pkg (see $h2spec_log)"
      fi
    done
  fi
fi

# --- nghttp ---
if command -v nghttp >/dev/null 2>&1; then
  if nghttp -n "http://127.0.0.1:$INTEROP_PORT/" >/dev/null 2>&1 </dev/null; then
    report_pass "nghttp GET /"
  else
    report_fail "nghttp GET /"
  fi
else
  report_fail "nghttp is required for server conformance"
fi

# --- curl ---
if command -v curl >/dev/null 2>&1; then
  code=$(curl -s --http2-prior-knowledge -o /dev/null \
    -w '%{http_code}' "http://127.0.0.1:$INTEROP_PORT/" 2>/dev/null </dev/null || echo 000)
  if [ "$code" = "200" ]; then
    report_pass "curl GET / (200)"
  else
    report_fail "curl GET / (code $code)"
  fi
  size=$(curl -s --http2-prior-knowledge -o /dev/null \
    -w '%{size_download}' "http://127.0.0.1:$INTEROP_PORT/large?bytes=8388608" \
    2>/dev/null </dev/null || echo 0)
  if [ "$size" = "8388608" ]; then
    report_pass "curl 8 MiB response (8388608 bytes)"
  else
    report_fail "curl 8 MiB response ($size bytes)"
  fi
else
  report_fail "curl is required for server conformance"
fi

# --- h2load ---
# The streams in flight are `-c` times `-m`, and the server admits
# `HandlerThreads + Queue.Depth` of them (4 + 64 = 68 in this build).  A
# larger product reaches the bound and the server refuses the excess with
# REFUSED_STREAM, which RFC 9113 section 8.7 permits.  This run stays inside
# the bound, so a refusal is a defect here.
if command -v h2load >/dev/null 2>&1; then
  h2load_log="$log_dir/h2load-$safe_gate-$run_id.log"
  h2load_requests="$log_dir/h2load-$safe_gate-$run_id-requests.tsv"
  if h2load -n 200 -c 10 -m 6 --log-file="$h2load_requests" \
     "http://127.0.0.1:$INTEROP_PORT/" </dev/null >"$h2load_log" 2>&1; then
    request_counts=$(awk -F '\t' 'NF >= 2 { total++; if ($2 == 200) ok++ } END { printf "%d %d", total, ok }' "$h2load_requests")
    if grep -Eq 'requests: 200 total, 200 started, 200 done, 200 succeeded, 0 failed, 0 errored' "$h2load_log" &&
       [ "$request_counts" = "200 200" ]; then
      report_pass "h2load 200 requests, 10 connections, 6 streams each (60 in flight)"
    else
      report_fail "h2load request results (expected 200 HTTP 200 responses; got $request_counts; see $h2load_log and $h2load_requests)"
    fi
  else
    report_fail "h2load 200 requests, 10 connections, 6 streams each (60 in flight; see $h2load_log)"
  fi
else
  report_fail "h2load is required for server conformance"
fi

# the checks above used the clear-text server; the TLS check starts its own
stop_interop_server

# --- HTTP/1.1 fallback, clear text ---
# The conformance run above used a server with the fallback off. This server
# keeps the fallback on, and one listener must give the same body on both
# protocols.
if command -v curl >/dev/null 2>&1; then
  if start_interop_server "$SERVER_BIN/interop_server"; then
    body1=$(curl -s --http1.1 "http://127.0.0.1:$INTEROP_PORT/" </dev/null)
    body2=$(curl -s --http2-prior-knowledge "http://127.0.0.1:$INTEROP_PORT/" </dev/null)
    if [ -n "$body1" ] && [ "$body1" = "$body2" ]; then
      report_pass "curl --http1.1 and --http2 give the same body (clear text)"
    else
      report_fail "curl --http1.1 and --http2 differ on clear text ('$body1' / '$body2')"
    fi
    stop_interop_server
  else
    report_fail "the fallback server did not report a port"
  fi
else
  report_fail "curl is required for the HTTP/1.1 fallback parity check"
fi

# --- TLS and ALPN ---
# One listener serves one transport, so the TLS checks start a second server
# with a certificate.  A certificate that is absent is created here.
if command -v openssl >/dev/null 2>&1; then
  cert_dir=$(ensure_validation_certificate "$work/certs")
  if [ -n "$cert_dir" ]; then
    if start_interop_server "$SERVER_BIN/interop_server" \
      --cert="$cert_dir/localhost.crt" --key="$cert_dir/localhost.key"; then
      tls_port=$INTEROP_PORT
      alpn=$(echo | openssl s_client -connect "127.0.0.1:$tls_port" -alpn h2 2>/dev/null \
        | sed -n 's/^ *ALPN protocol: *//p' | head -1)
      if [ "$alpn" = "h2" ]; then
        report_pass "openssl s_client negotiates ALPN h2"
      else
        report_fail "openssl s_client ALPN result ($alpn)"
      fi
      if command -v curl >/dev/null 2>&1; then
        tbody1=$(curl -sk -m 10 --http1.1 "https://127.0.0.1:$tls_port/" </dev/null)
        tbody2=$(curl -sk -m 10 --http2 "https://127.0.0.1:$tls_port/" </dev/null)
        if [ -n "$tbody1" ] && [ "$tbody1" = "$tbody2" ]; then
          report_pass "curl --http1.1 and --http2 give the same body (TLS)"
        else
          report_fail "curl --http1.1 and --http2 differ over TLS ('$tbody1' / '$tbody2')"
        fi
        # a request with Connection: close takes the close path of a TLS connection
        tbody3=$(curl -sk -m 10 --http1.1 -H 'Connection: close' "https://127.0.0.1:$tls_port/" </dev/null)
        if [ -n "$tbody3" ] && [ "$tbody3" = "$tbody1" ]; then
          report_pass "curl --http1.1 with Connection: close over TLS"
        else
          report_fail "curl --http1.1 with Connection: close over TLS ('$tbody3')"
        fi
      fi
      stop_interop_server
      # with the fallback off, a client that offers only http/1.1 is refused
      if command -v curl >/dev/null 2>&1 &&
         start_interop_server "$SERVER_BIN/interop_server" no-http11 \
           --cert="$cert_dir/localhost.crt" --key="$cert_dir/localhost.key"; then
        if curl -sk -m 10 --http1.1 "https://127.0.0.1:$INTEROP_PORT/" </dev/null >/dev/null 2>&1; then
          report_fail "TLS with the fallback off still served HTTP/1.1"
        elif curl -sk -m 10 --http2 "https://127.0.0.1:$INTEROP_PORT/" </dev/null >/dev/null 2>&1; then
          report_pass "TLS with the fallback off refuses http/1.1 and serves h2"
        else
          report_fail "TLS with the fallback off refused h2 too"
        fi
        stop_interop_server
      fi
    else
      report_fail "the TLS server did not report a port"
    fi
  else
    report_fail "the TLS certificate could not be created"
  fi
else
  report_fail "openssl is required for server TLS conformance"
fi

# --- WebSocket over HTTP/2 (RFC 8441) with h2 and wsproto ---
# WS_PYTHON names a Python that holds the packages h2 and wsproto.
ws_python="${WS_PYTHON:-python3}"
if [ -x "$SERVER_BIN/ws_echo" ] && "$ws_python" -c 'import h2, wsproto' >/dev/null 2>&1; then
  if start_example_server "$SERVER_BIN/ws_echo" 127.0.0.1 0 big; then
    ws_port=$EXAMPLE_PORT
  else
    report_fail "WebSocket example server did not become ready"
    ws_port=''
  fi
  ws_out="$work/ws"
  if [ -n "$ws_port" ] &&
     "$ws_python" "$here/ws_h2_client.py" 127.0.0.1 "$ws_port" </dev/null >"$ws_out.client" 2>&1; then
    report_pass "WebSocket echo over HTTP/2 with h2 and wsproto (32 checks)"
  elif [ -n "$ws_port" ]; then
    report_fail "WebSocket echo over HTTP/2 with h2 and wsproto"
    cat "$EXAMPLE_OUT" "$ws_out.client" 2>/dev/null
  fi
  stop_example_server
else
  report_fail "WebSocket over HTTP/2 requires ws_echo and Python packages h2 and wsproto"
fi

# --- WebSocket over HTTP/1.1 ---
if [ -x "$SERVER_BIN/ws_echo" ]; then
  if start_example_server "$SERVER_BIN/ws_echo" 127.0.0.1 0; then
    if python3 "$here/ws_h1_client.py" 127.0.0.1 "$EXAMPLE_PORT"; then
      report_pass "WebSocket echo over HTTP/1.1 (5 checks)"
    else
      report_fail "WebSocket echo over HTTP/1.1"
    fi
  else
    report_fail "WebSocket HTTP/1.1 server did not become ready"
  fi
  stop_example_server
else
  report_fail "WebSocket over HTTP/1.1 requires ws_echo"
fi

# --- Server-sent events on both protocols ---
if [ -x "$SERVER_BIN/sse_replay" ] && command -v curl >/dev/null 2>&1; then
  if start_example_server "$SERVER_BIN/sse_replay" 127.0.0.1 0; then
    sse_port=$EXAMPLE_PORT
    sse_report=$(sh "$here/sse_check.sh" 127.0.0.1 "$sse_port" 2>&1) || exit_code=1
    echo "$sse_report"
  else
    report_fail "SSE: the example server did not start"
  fi
  stop_example_server
else
  report_fail "SSE conformance requires sse_replay and curl"
fi

exit "$exit_code"
