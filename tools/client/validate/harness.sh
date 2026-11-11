#!/usr/bin/env bash
# tools/client/validate/harness.sh — doc/verification/validation.md section B
# (nomadlabsinc/h2-client-test-harness, the primary RFC gate).
#
# For every id from `docker run --rm h2-test-harness --list` this script:
#   1. measures the REFERENCE outcome by running the harness's own Go verifier
#      (`docker run --rm h2-test-harness --test=<id>`), and
#   2. measures OUR outcome by starting the harness server (detached, host
#      network) and running tools/client/h2probe against it,
# then classifies the id MATCH / BETTER / WORSE / UNKNOWN.
#
# It writes the full per-id table to the target and profile validation
# directory and prints a summary. It is re-runnable and independent of the
# repo build state.
#
# Verdict model (approved direction):
#   PASS = MATCH or BETTER;  FAIL = WORSE;  UNKNOWN counted separately.
#   MATCH  : our outcome class == the reference's.
#   BETTER : we produced a connection/stream error where the reference only
#            stayed open / timed out (a genuine conformance improvement).
#   WORSE  : the reference detected an error (or got a success) and we only
#            timed out / stayed open (a real client bug).
#   UNKNOWN: neither side resolves to an outcome class.
#
# The outcome class for every id is DECLARED in
# doc/verification/source/client/harness-expectations.tsv, generated from the harness verifier
# sources. The reference run only tells us whether it demonstrated that declared
# outcome; where it could not (Go's verifier fails, or the whole oracle was
# invalid) a declared outcome we DO meet still counts as BETTER rather than
# being scored against a broken oracle.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"
if [ -z "${TARGET:-}" ]; then TARGET="$("${FPC:-fpc}" -iTP)-$("${FPC:-fpc}" -iTO)"; fi
if [ -z "${PROFILE:-}" ]; then
  PROFILE=default
  [ -n "${DEBUG:-}" ] && PROFILE=debug
fi

VALIDATION_DIR="$REPO_ROOT/bin/$TARGET/$PROFILE/validation"
mkdir -p "$VALIDATION_DIR"
RUN_DIR="$(mktemp -d "$VALIDATION_DIR/harness-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
BUILD="$(mktemp -d /tmp/h2harness-build.XXXXXX)"
PROBE="$BUILD/h2probe"
OUT_MD="${OUT_MD:-$VALIDATION_DIR/harness-results.md}"
RESULTS_TSV="$RUN_DIR/results.tsv"
EXPECTED_IDS="$RUN_DIR/expected-ids.txt"
PRODUCED_IDS="$RUN_DIR/produced-ids.txt"
REFERENCE_DIR="$RUN_DIR/reference"
CLIENT_DIR="$RUN_DIR/client"
BUILD_LOG="$RUN_DIR/build.log"
mkdir -p "$REFERENCE_DIR" "$CLIENT_DIR"

FPC="${FPC:-fpc}"
MORMOT="${MORMOT:-third_party/mORMot2/src}"

DOCKER="$(command -v docker || true)"
IMG="h2-test-harness"
CONTAINER="h2harness-$$"
PROBE_TIMEOUT_MS="${PROBE_TIMEOUT_MS:-4000}"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1
  rm -rf "$BUILD" 2>/dev/null
}
trap cleanup EXIT

if [ -z "$DOCKER" ]; then
  echo "ERROR: docker not found on PATH" >&2
  exit 1
fi

# --- static expectation annotation (from verifier/cases/*.go source) --------
# --- declared expectations (authority: the verifier's own sources) ----------
# doc/verification/source/client/harness-expectations.tsv is generated from
# third_party/h2-client-test-harness/verifier/cases/*.go by
# tools/client/validate/extract_expectations.py. Each row is "<id>\t<expectation>"
# with expectation in {success, conn-error, stream-error}.
#
# Why the declared table and not the reference run's own wording: the image's
# verifier matches SUBSTRINGS of the Go client's error text, so a case declared
# as ExpectConnectionError can still log "Verifier passed" while Go actually
# reported a *stream* error (e.g. 5.1/1, 6.2/4). Scoring us against that
# observed wording would import Go's imprecision; the declaration is the rule.
EXPECTATIONS="$REPO_ROOT/doc/verification/source/client/harness-expectations.tsv"
if [ ! -f "$EXPECTATIONS" ]; then
  echo "ERROR: $EXPECTATIONS missing; regenerate with:" >&2
  echo "  python3 tools/client/validate/extract_expectations.py \\" >&2
  echo "      third_party/h2-client-test-harness/verifier/cases \\" >&2
  echo "      > doc/verification/source/client/harness-expectations.tsv" >&2
  exit 1
fi

declared_intent() { # id -> success|conn-error|stream-error|'' (absent)
  awk -F'\t' -v id="$1" '$1 == id { print $2; exit }' "$EXPECTATIONS"
}

# ids whose harness case writes a response :status (source-derived)
STATUS_WRITERS="6.10/2 6.9/2 8.1/1 8.1.2/1 8.1.2.1/1 8.1.2.1/2 8.1.2.1/3 \
8.1.2.1/4 8.1.2.2/1 8.1.2.2/2 8.1.2.3/1 8.1.2.6/1 8.1.2.6/2 hpack/2.3.3/1 \
hpack/2.3.3/2 hpack/4.2/1 http2/8.1.2.4/1 6.10/3 6.10/4 6.10/5 6.10/6"

wrote_status() { # id -> yes/no
  local x
  for x in $STATUS_WRITERS; do [ "$x" = "$1" ] && { echo yes; return; }; done
  echo no
}

compile_probe() {
  "$FPC" -O2 -Mdelphi -dUSE_OPENSSL -Fu./common/src -Fu./client/src -Fu./server/src -Fu./test/client -Fu./tls/openssl/src -Fu"$BUILD" \
    -Fu"$MORMOT/core" -Fu"$MORMOT/lib" -Fu"$MORMOT/net" -Fu"$MORMOT/crypt" \
    -Fl"$MORMOT/../static/$("$FPC" -iTP)-$("$FPC" -iTO)" \
    -FU"$BUILD" -FE"$BUILD" tools/client/h2probe.pas >"$BUILD_LOG" 2>&1 || {
    echo "ERROR: h2probe failed to compile; see $BUILD_LOG" >&2
    tail -20 "$BUILD_LOG" >&2; exit 1; }
}

classify_ref_log() { # logfile id -> "pass|fail class"
  # The reference run tells us only whether the reference client produced the
  # declared outcome. The EXPECTED class itself comes from the declarations in
  # doc/verification/source/client/harness-expectations.tsv (see declared_intent), NOT from the reference
  # log: the image's verifier matches error SUBSTRINGS, so its own wording can
  # disagree with the case author's expectation.
  #
  # A positive control (BASELINE_ID) must pass first; if it does not, the
  # reference is not trustworthy and every row is downgraded to fail/invalid.
  local log="$1"
  if [ "${BASELINE_OK:-}" != yes ]; then echo "fail invalid"; return; fi
  if grep -q 'Got successful response as expected' "$log"; then
    echo "pass success"; return
  fi
  if grep -q 'Got expected error\|Got expected stream error' "$log"; then
    # record the level Go happened to produce (fallback scoring only)
    if grep -q 'stream error' "$log"; then echo "pass stream-error"; return; fi
    echo "pass conn-error"; return
  fi
  if grep -q 'unexpected EOF' "$log"; then
    echo "fail eof"
  else
    echo "fail unresolved"
  fi
}

classify_our_line() { # RESULT line (+ msg) -> class
  local line="$1"
  if echo "$line" | grep -q "RESULT=success"; then echo success
  elif echo "$line" | grep -qi "timed out"; then echo timeout
  elif echo "$line" | grep -q "RESULT=stream-error"; then echo stream-error
  elif echo "$line" | grep -q "RESULT=conn-error"; then echo conn-error
  else echo unresolved; fi
}

is_infrastructure_failure() { # probe exit, case log prefix -> 0 for NOT_READY or killed without RESULT
  local rc="$1" prefix="$2" log
  [ "$rc" = 999 ] && return 0
  [ "$rc" = 137 ] || return 1
  for log in "$prefix".attempt*.log; do
    [ -f "$log" ] || continue
    grep -q '^RESULT=' "$log" && return 1
  done
  return 0
}

verdict_for() { # ref_state ref_class our id -> verdict
  local rstate="$1" rclass="$2" our="$3" id="$4" expected
  local our_err=false
  { [ "$our" = conn-error ] || [ "$our" = stream-error ]; } && our_err=true
  expected="$(declared_intent "$id")"

  # No declaration for this id: fall back to whatever class the reference run
  # happened to demonstrate.
  if [ -z "$expected" ]; then
    if [ "$rstate" = fail ]; then
      if [ "$our_err" = true ]; then echo "BETTER"; else echo "UNKNOWN"; fi
    elif [ "$our" = "$rclass" ]; then
      echo "MATCH"
    else
      echo "UNKNOWN"
    fi
    return
  fi

  if [ "$our" = "$expected" ]; then
    # We produced exactly what the case declares. When the reference ALSO
    # demonstrated it, that is a MATCH; when the reference could not, the
    # declaration is still satisfied -> BETTER.
    if [ "$rstate" = pass ]; then echo "MATCH"; else echo "BETTER"; fi
    return
  fi

  if [ "$expected" != success ] && [ "$our_err" = true ]; then
    # both are errors, at different levels: a real divergence to justify
    echo "CLASS-DIFF"
    return
  fi

  # We did not meet the declared outcome. That is a genuine failure only when
  # the reference demonstrated the declared outcome; otherwise it is
  # inconclusive (the environment could not show either side).
  if [ "$rstate" = pass ]; then echo "WORSE"; else echo "UNKNOWN"; fi
}

port_open() { # host port
  if command -v nc >/dev/null 2>&1; then
    nc -z "$1" "$2" 2>/dev/null
  else
    (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null
  fi
}

wait_port() { # host port [tenths] -> 0 when open, 1 when never opened
  local host="$1" port="$2" tries="${3:-100}" i
  for i in $(seq 1 "$tries"); do
    port_open "$host" "$port" && return 0
    sleep 0.1
  done
  return 1
}

wait_harness_ready() {
  local i
  for i in $(seq 1 100); do
    docker logs "$CONTAINER" 2>&1 | grep -q "listening on" && return 0
    sleep 0.1
  done
  return 1
}

safe_id() { # id -> run-scoped artifact name
  printf '%s' "$1" | tr '/:' '__'
}

run_reference() { # id logfile -> run verifier and preserve complete output
  docker run --rm "$IMG" --test="$1" >"$2" 2>&1
}

run_ours() { # id logfile -> echo "exit line" and preserve every attempt
  # A NOT_READY result means the harness container did not finish binding
  # 127.0.0.1:8080 within the readiness window (host load, image warm-up);
  # it says nothing about the client. The host listener is an ssh-forwarded
  # port established a moment after the container logs "listening on", so a
  # probe fired on the log line alone can still hit "connect ... failed" --
  # an infrastructure race, not a client result. Detect that specific failure
  # and retry a bounded number of times. Do NOT probe readiness with a TCP
  # connect: the harness accepts exactly one connection and exits, so a
  # connect probe would consume the accept and break the real run.
  local attempt out rc logfile="$2"
  for attempt in 1 2 3; do
    docker rm -f "$CONTAINER" >/dev/null 2>&1
    docker run -d --name "$CONTAINER" --network host "$IMG" \
      --harness-only --test="$1" >/dev/null 2>&1
    if wait_harness_ready; then
      out="$(timeout_guard "$PROBE" --url=https://127.0.0.1:8080/ --insecure \
        --timeout-ms="$PROBE_TIMEOUT_MS" --keep-open-ms=200 2>&1)"
      rc=$?
      printf '%s\n' "$out" >"$logfile.attempt$attempt.log"
      docker logs "$CONTAINER" >"$logfile.server.attempt$attempt.log" 2>&1 || true
      docker rm -f "$CONTAINER" >/dev/null 2>&1
      if [ "$attempt" -lt 3 ] && echo "$out" | grep -q "connect to 127.0.0.1:8080 failed"; then
        # host forwarder not established yet: retry, do not score this run
        sleep 1
        continue
      fi
      echo "$rc $(echo "$out" | head -1)"
      return
    fi
    docker logs "$CONTAINER" >"$logfile.server.attempt$attempt.log" 2>&1 || true
    docker rm -f "$CONTAINER" >/dev/null 2>&1
    sleep 1
  done
  printf '%s\n' '999 NOT_READY' >"$logfile.attempt3.log"
  echo "999 NOT_READY"
}

# a tiny timeout guard (macOS has no `timeout`): run in background, kill after N
timeout_guard() {
  local secs=$(( (PROBE_TIMEOUT_MS / 1000) + 5 ))
  "$@" & local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) & local wd=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill "$wd" 2>/dev/null
  return $rc
}

echo "== http2client harness validation ($IMG) =="
echo "image:    $(docker image inspect "$IMG" --format '{{.Id}}' 2>/dev/null | cut -c1-19)"
echo "run dir:  $RUN_DIR"
echo

if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  echo "ERROR: image '$IMG' not built. Build it from" \
    "third_party/h2-client-test-harness first." >&2
  exit 1
fi

compile_probe

if ! docker run --rm "$IMG" --list >"$RUN_DIR/image-list.log" 2>&1; then
  echo "ERROR: harness image could not list its test ids; see $RUN_DIR/image-list.log" >&2
  exit 1
fi
sed -n 's/^  - //p' "$RUN_DIR/image-list.log" >"$RUN_DIR/image-ids.txt"
if [ ! -s "$RUN_DIR/image-ids.txt" ]; then
  echo "ERROR: harness image produced an empty test id list; see $RUN_DIR/image-list.log" >&2
  exit 1
fi
if [ -n "$(sort "$RUN_DIR/image-ids.txt" | uniq -d)" ]; then
  echo "ERROR: harness image listed duplicate ids; see $RUN_DIR/image-ids.txt" >&2
  exit 1
fi

if ! awk -F '\t' 'NF != 2 || $1 == "" || $2 !~ /^(success|conn-error|stream-error)$/ { exit 1 }' \
    "$EXPECTATIONS"; then
  echo "ERROR: malformed harness expectation table: $EXPECTATIONS" >&2
  exit 1
fi
cut -f1 "$EXPECTATIONS" >"$RUN_DIR/expectation-ids.txt"
if [ -n "$(sort "$RUN_DIR/expectation-ids.txt" | uniq -d)" ]; then
  echo "ERROR: expectation table contains duplicate ids: $EXPECTATIONS" >&2
  exit 1
fi
sort "$RUN_DIR/image-ids.txt" >"$RUN_DIR/image-ids.sorted.txt"
sort "$RUN_DIR/expectation-ids.txt" >"$RUN_DIR/expectation-ids.sorted.txt"
if ! cmp -s "$RUN_DIR/image-ids.sorted.txt" "$RUN_DIR/expectation-ids.sorted.txt"; then
  echo "ERROR: harness image ids do not match declared expectations; see $RUN_DIR/image-ids.sorted.txt and $RUN_DIR/expectation-ids.sorted.txt" >&2
  diff -u "$RUN_DIR/expectation-ids.sorted.txt" "$RUN_DIR/image-ids.sorted.txt" >&2 || true
  exit 1
fi

mapfile -t ALL_IDS <"$RUN_DIR/image-ids.txt"
if [ -n "${HARNESS_IDS:-}" ]; then
  mapfile -t IDS < <(for x in $HARNESS_IDS; do echo "$x"; done)
else
  IDS=("${ALL_IDS[@]}")
fi
if [ "${#IDS[@]}" -eq 0 ]; then
  echo "ERROR: no harness ids were selected" >&2
  exit 1
fi
printf '%s\n' "${IDS[@]}" >"$EXPECTED_IDS"
if [ -n "$(sort "$EXPECTED_IDS" | uniq -d)" ]; then
  echo "ERROR: selected harness ids contain duplicates; see $EXPECTED_IDS" >&2
  exit 1
fi
for id in "${IDS[@]}"; do
  if ! grep -Fxq "$id" "$RUN_DIR/image-ids.txt"; then
    echo "ERROR: selected harness id '$id' is not in the image list" >&2
    exit 1
  fi
done
sort "$EXPECTED_IDS" >"$RUN_DIR/selected-ids.sorted.txt"
if cmp -s "$RUN_DIR/selected-ids.sorted.txt" "$RUN_DIR/image-ids.sorted.txt"; then
  FULL_SWEEP=yes
else
  FULL_SWEEP=no
fi
echo "ids:      ${#ALL_IDS[@]} image ids; ${#IDS[@]} selected; full sweep=$FULL_SWEEP"
if [ -n "${HARNESS_IDS:-}" ]; then
  echo "scope:    selected ids only (diagnostic run)"
fi
echo "running ${#IDS[@]} ids (reference + probe each)..." >&2

# Positive control: a case the Go verifier must pass. If it does not, the
# reference image (or the environment) is broken and no row can be trusted.
BASELINE_ID="${BASELINE_ID:-6.5/1}"
BASELINE_OK=no
mkdir -p "$BUILD" "$(dirname "$OUT_MD")"
BASELINE_LOG="$REFERENCE_DIR/baseline-$(safe_id "$BASELINE_ID").log"
run_reference "$BASELINE_ID" "$BASELINE_LOG"
BASELINE_RC=$?
printf '%s\n' "$BASELINE_RC" >"$RUN_DIR/baseline.exit"
if [ "$BASELINE_RC" = 0 ] && grep -q 'Verifier passed' "$BASELINE_LOG"; then
  BASELINE_OK=yes
else
  echo "WARNING: reference positive control $BASELINE_ID did not pass;" \
    "scoring every row as invalid (see $BASELINE_LOG)" >&2
fi
export BASELINE_OK

: > "$RESULTS_TSV"
n_match=0; n_better=0; n_worse=0; n_unknown=0; n_classdiff=0; n_ref_pass=0
n_infrastructure=0
for id in "${IDS[@]}"; do
  id_file="$(safe_id "$id")"
  ref_log="$REFERENCE_DIR/$id_file.log"
  client_log="$CLIENT_DIR/$id_file"
  run_reference "$id" "$ref_log"
  ref_rc=$?
  if grep -q 'Verifier passed' "$ref_log"; then
    n_ref_pass=$((n_ref_pass+1))
  fi
  ref_state_class="$(classify_ref_log "$ref_log" "$id")"
  ref_state="${ref_state_class%% *}"; ref_class="${ref_state_class#* }"
  ours="$(run_ours "$id" "$client_log")"
  our_rc="${ours%% *}"; our_line="${ours#* }"
  our_class="$(classify_our_line "$our_line")"
  if is_infrastructure_failure "$our_rc" "$client_log"; then
    n_infrastructure=$((n_infrastructure+1))
  fi
  verdict="$(verdict_for "$ref_state" "$ref_class" "$our_class" "$id")"
  case "$verdict" in
    MATCH) n_match=$((n_match+1));;
    BETTER) n_better=$((n_better+1));;
    WORSE) n_worse=$((n_worse+1));;
    CLASS-DIFF) n_classdiff=$((n_classdiff+1));;
    UNKNOWN) n_unknown=$((n_unknown+1));;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$ref_rc" "$ref_state" "$ref_class" "$our_rc" "$our_class" \
    "$(declared_intent "$id")" "$verdict" "$our_line" \
    >> "$RESULTS_TSV"
  printf '  %-16s ref=%-4s/%-12s ours=%-13s %s\n' \
    "$id" "$ref_state" "$ref_class" "$our_class" "$verdict" >&2
done

cut -f1 "$RESULTS_TSV" >"$PRODUCED_IDS"
ACCOUNTING_OK=yes
if ! cmp -s "$EXPECTED_IDS" "$PRODUCED_IDS" ||
   [ -n "$(sort "$PRODUCED_IDS" | uniq -d)" ]; then
  ACCOUNTING_OK=no
  echo "ERROR: produced result ids do not exactly match selected ids; see $EXPECTED_IDS, $PRODUCED_IDS, and $RESULTS_TSV" >&2
fi

{
  echo "# Harness validation results (section B)"
  echo
  echo "Generated by \`tools/client/validate/harness.sh\`."
  echo
  echo "Image: \`$IMG\`  ($(docker image inspect "$IMG" --format '{{.Id}}' 2>/dev/null | cut -c1-19))"
  echo
  echo "Go reference verifier tally: $n_ref_pass / ${#IDS[@]} ids passed."
  echo
  echo "Scope: $FULL_SWEEP (${#IDS[@]} of ${#ALL_IDS[@]} image ids)."
  echo
  echo "Case accounting: $ACCOUNTING_OK. Run artifacts: $RUN_DIR."
  echo
  echo "Positive control (${BASELINE_ID:-6.5/1}): ${BASELINE_OK:-no}"
  echo
  echo "PASS = MATCH+BETTER = $((n_match+n_better));  FAIL = WORSE = $n_worse;  CLASS-DIFF = $n_classdiff;  UNKNOWN = $n_unknown;  INFRASTRUCTURE = $n_infrastructure"
  echo
  echo "| id | ref exit | ref state | ref class | our exit | our outcome | static intent | verdict | our RESULT |"
  echo "|---|---|---|---|---|---|---|---|---|"
  while IFS=$'\t' read -r id ref_rc rstate rclass rc our intent verdict line; do
    [ -z "$id" ] && continue
    echo "| $id | $ref_rc | $rstate | $rclass | $rc | $our | $intent | $verdict | \`$line\` |"
  done < "$RESULTS_TSV"
} > "$OUT_MD"

echo
echo "harness: MATCH=$n_match BETTER=$n_better WORSE=$n_worse CLASS-DIFF=$n_classdiff UNKNOWN=$n_unknown INFRASTRUCTURE=$n_infrastructure"
echo "wrote $OUT_MD"
cp -p "$OUT_MD" "$RUN_DIR/results.md"
echo "artifacts: $RUN_DIR"
if [ "$ACCOUNTING_OK" != yes ]; then
  echo "RESULT: FAIL (case accounting mismatch)"
  exit 1
fi
if [ "$BASELINE_OK" != yes ]; then
  echo "RESULT: FAIL (reference positive control did not pass)"
  exit 1
fi
if [ "$FULL_SWEEP" != yes ]; then
  echo "RESULT: PARTIAL selected=${#IDS[@]} expected=${#ALL_IDS[@]} PASS=$((n_match+n_better)) FAIL=$n_worse CLASS-DIFF=$n_classdiff UNKNOWN=$n_unknown INFRASTRUCTURE=$n_infrastructure"
  exit 2
fi
if [ "$n_infrastructure" -gt 0 ]; then
  echo "RESULT: FAIL PASS=$((n_match+n_better)) FAIL=$n_worse CLASS-DIFF=$n_classdiff UNKNOWN=$n_unknown INFRASTRUCTURE=$n_infrastructure"
  exit 1
fi
echo "RESULT: PASS=$((n_match+n_better)) FAIL=$n_worse CLASS-DIFF=$n_classdiff UNKNOWN=$n_unknown INFRASTRUCTURE=0"
[ "$n_worse" -eq 0 ]
