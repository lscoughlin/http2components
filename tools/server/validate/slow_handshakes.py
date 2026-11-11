#!/usr/bin/env python3
"""Measure TLS handshake timeout and admission under incomplete peer load.

Use PROVIDER_LIVE_BINARY to select an existing ProviderLive executable.
The target is configured with a 1000 ms handshake timeout and a 64 connection
limit. The async listener reserves each connection slot before it enters the
first-read queue. It must close excess peers within the capacity observation
window and retain the accepted peers until their handshake deadlines.
"""

from __future__ import annotations

import errno
import os
import queue
import re
import select
import socket
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from provider_live import BODY, ROOT, http2_get, provider_binary
from ws_sse_load import cpu_seconds


HANDSHAKE_TIMEOUT_MS = 1000
MAX_CONNECTIONS = 64
EFFECTIVE_CONNECTION_LIMIT = MAX_CONNECTIONS
SILENT_PEERS = 64
PARTIAL_PEERS = 64
ADMISSION_OBSERVE_MS = 200
SCHEDULER_MARGIN_MS = 2500
SAMPLE_INTERVAL_SECONDS = 0.1


@dataclass
class Peer:
    index: int
    kind: str
    sock: socket.socket | None
    started: float
    admission: str = "pending"
    admission_observed_ms: int = -1
    close_kind: str = "open"
    close_ms: int = -1
    first_data_hex: str = ""
    tcp_connected: bool = False


def client_hello_prefix() -> bytes:
    """Build a valid ClientHello record prefix that ends inside the random."""
    body = (
        b"\x03\x03" + bytes(range(32)) + b"\x00" +
        b"\x00\x02\x13\x01" + b"\x01\x00" + b"\x00\x00"
    )
    hello = b"\x01" + len(body).to_bytes(3, "big") + body
    record = b"\x16\x03\x01" + len(hello).to_bytes(2, "big") + hello
    return record[:5 + 4 + 2 + 8]


def process_stats(pid: int) -> tuple[int, float, int]:
    result = subprocess.run(
        ["ps", "-o", "rss=,time=", "-p", str(pid)],
        check=True, capture_output=True, text=True,
    )
    fields = result.stdout.split()
    if len(fields) != 2:
        raise RuntimeError(f"server process {pid} is absent from ps")
    fd_dir = Path(f"/proc/{pid}/fd")
    if not fd_dir.is_dir():
        raise RuntimeError("file descriptor sampling requires Linux /proc")
    return int(fields[0]), cpu_seconds(fields[1]), len(list(fd_dir.iterdir()))


def read_server_output(process: subprocess.Popen[str], log_path: Path,
                       events: queue.Queue[tuple[str, object]]) -> None:
    with log_path.open("w", encoding="utf-8") as log:
        for line in process.stdout or ():
            log.write(line)
            log.flush()
            ready_match = re.fullmatch(r"READY port (\d+)\s*", line)
            stats_match = re.fullmatch(r"STATS accepted (\d+)\s*", line)
            if ready_match:
                events.put(("ready", int(ready_match.group(1))))
            elif stats_match:
                events.put(("stats", int(stats_match.group(1))))
        events.put(("eof", EOFError("ProviderLive closed stdout")))


def wait_ready(process: subprocess.Popen[str], events: queue.Queue[tuple[str, object]]) -> int:
    try:
        kind, value = events.get(timeout=10)
    except queue.Empty as error:
        raise TimeoutError("ProviderLive did not report READY in 10 seconds") from error
    if kind != "ready":
        raise RuntimeError(str(value))
    if process.poll() is not None:
        raise RuntimeError(f"ProviderLive exited before READY ({process.returncode})")
    return int(value)


def start_server(binary: Path, provider: str, certificate: str, key: str,
                 version: str, raw_dir: Path) -> tuple[subprocess.Popen[str], int,
                                                     threading.Thread,
                                                     queue.Queue[tuple[str, object]]]:
    environment = os.environ.copy()
    environment["HTTP2_TEST_HANDSHAKE_TIMEOUT_MS"] = str(HANDSHAKE_TIMEOUT_MS)
    environment["HTTP2_TEST_MAX_CONNECTIONS"] = str(MAX_CONNECTIONS)
    process = subprocess.Popen(
        [str(binary), provider, certificate, key, version],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1, env=environment,
    )
    events: queue.Queue[tuple[str, object]] = queue.Queue()
    reader = threading.Thread(
        target=read_server_output,
        args=(process, raw_dir / "server.log", events), daemon=True,
    )
    try:
        reader.start()
        port = wait_ready(process, events)
    except BaseException:
        stop_server(process, reader)
        raise
    return process, port, reader, events


def server_accepted_count(process: subprocess.Popen[str],
                          events: queue.Queue[tuple[str, object]]) -> int:
    if process.stdin is None:
        raise RuntimeError("ProviderLive has no control input")
    process.stdin.write("stats\n")
    process.stdin.flush()
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        try:
            kind, value = events.get(timeout=deadline - time.monotonic())
        except queue.Empty as error:
            raise TimeoutError("ProviderLive did not report connection count") from error
        if kind == "stats":
            return int(value)
        if kind == "eof":
            raise RuntimeError("ProviderLive closed before its stats response")
    raise TimeoutError("ProviderLive did not report connection count")


def make_peer(port: int, index: int, kind: str) -> Peer:
    started = time.monotonic()
    try:
        peer = socket.create_connection(("127.0.0.1", port), timeout=1.0)
    except ConnectionRefusedError as error:
        return Peer(index, kind, None, started, admission="tcp_connection_refused",
                    close_kind=f"connect_error:{type(error).__name__}",
                    close_ms=round((time.monotonic() - started) * 1000))
    except ConnectionResetError:
        return Peer(index, kind, None, started,
                    admission="server_closed_during_capacity_observation",
                    close_kind="server_reset",
                    close_ms=round((time.monotonic() - started) * 1000))
    except OSError as error:
        return Peer(index, kind, None, started, admission="peer_connect_error",
                    close_kind=f"connect_error:{type(error).__name__}",
                    close_ms=round((time.monotonic() - started) * 1000))
    peer.setblocking(False)
    item = Peer(index, kind, peer, started, tcp_connected=True)
    if kind == "partial_client_hello":
        try:
            peer.sendall(client_hello_prefix())
        except ConnectionResetError:
            item.close_kind = "server_reset"
            item.admission = "server_closed_during_capacity_observation"
            item.close_ms = round((time.monotonic() - started) * 1000)
            peer.close()
            item.sock = None
        except OSError as error:
            item.close_kind = f"write_error:{type(error).__name__}"
            item.admission = "client_write_error"
            item.close_ms = round((time.monotonic() - started) * 1000)
            peer.close()
            item.sock = None
    return item


def poll_peer(peer: Peer, now: float) -> bool:
    """Update state; return true when this call observed a socket close."""
    if peer.sock is None or peer.close_kind != "open":
        return False
    try:
        readable, _, exceptional = select.select([peer.sock], [], [peer.sock], 0)
    except (OSError, ValueError):
        peer.close_kind = "select_error"
        peer.close_ms = round((now - peer.started) * 1000)
        peer.sock.close()
        peer.sock = None
        return True
    if exceptional:
        socket_error = peer.sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
        if socket_error == 0:
            return False
        peer.close_kind = (
            "server_reset" if socket_error == errno.ECONNRESET
            else f"socket_error:{socket_error}"
        )
    elif readable:
        try:
            data = peer.sock.recv(65535)
        except BlockingIOError:
            return False
        except OSError as error:
            peer.close_kind = (
                "server_reset" if isinstance(error, ConnectionResetError)
                else f"socket_error:{type(error).__name__}"
            )
        else:
            if data:
                if not peer.first_data_hex:
                    peer.first_data_hex = data[:64].hex()
                return False
            peer.close_kind = "eof"
    else:
        return False
    peer.close_ms = round((now - peer.started) * 1000)
    peer.sock.close()
    peer.sock = None
    return True


def sample(process: subprocess.Popen[str], peers: list[Peer], samples) -> tuple[int, float, int]:
    rss, cpu, fds = process_stats(process.pid)
    active = sum(peer.sock is not None and peer.close_kind == "open" for peer in peers)
    samples.write(f"{time.monotonic():.6f}\t{rss}\t{cpu:.3f}\t{fds}\t{active}\n")
    samples.flush()
    return rss, cpu, fds


def observe_window(process: subprocess.Popen[str], peers: list[Peer], samples,
                   peak: tuple[int, float, int], duration_ms: int
                   ) -> tuple[int, float, int]:
    deadline = time.monotonic() + duration_ms / 1000
    last_sample = 0.0
    while time.monotonic() < deadline:
        now = time.monotonic()
        for peer in peers:
            if peer.sock is not None:
                poll_peer(peer, now)
        if now - last_sample >= SAMPLE_INTERVAL_SECONDS:
            current = sample(process, peers, samples)
            peak = (max(peak[0], current[0]), max(peak[1], current[1]),
                    max(peak[2], current[2]))
            last_sample = now
        time.sleep(0.01)
    return peak


def settle_fds(process: subprocess.Popen[str], peers: list[Peer], samples,
               target: int | None, timeout_seconds: float = 5.0
               ) -> tuple[tuple[int, float, int], float]:
    started = time.monotonic()
    deadline = started + timeout_seconds
    previous = None
    stable = 0
    latest = (0, 0.0, 0)
    while time.monotonic() < deadline:
        latest = sample(process, peers, samples)
        if target is None:
            stable = stable + 1 if latest[2] == previous else 0
        else:
            stable = stable + 1 if latest[2] == target else 0
        if stable >= 3:
            return latest, time.monotonic() - started
        previous = latest[2]
        time.sleep(SAMPLE_INTERVAL_SECONDS)
    expected = "three stable samples" if target is None else f"FD count {target}"
    raise TimeoutError(f"process FD count did not settle to {expected} in {timeout_seconds}s")


def hold_and_measure(process: subprocess.Popen[str], peers: list[Peer], samples,
                     prior_peak: tuple[int, float, int]
                     ) -> tuple[tuple[int, float, int], tuple[int, float, int]]:
    peak = prior_peak
    last_sample = 0.0
    final_deadline = max(peer.started for peer in peers) + (
        HANDSHAKE_TIMEOUT_MS + SCHEDULER_MARGIN_MS
    ) / 1000
    while time.monotonic() < final_deadline:
        now = time.monotonic()
        for peer in peers:
            if peer.sock is not None:
                poll_peer(peer, now)
        if now - last_sample >= SAMPLE_INTERVAL_SECONDS:
            rss, cpu, fds = sample(process, peers, samples)
            peak = (max(peak[0], rss), max(peak[1], cpu), max(peak[2], fds))
            last_sample = now
        if all(peer.sock is None for peer in peers):
            break
        time.sleep(0.01)
    for peer in peers:
        if peer.sock is not None:
            poll_peer(peer, time.monotonic())
    final_stats = sample(process, peers, samples)
    return peak, final_stats


def during_load_request(port: int, version: str, ca_file: str,
                        admitted: int, output: Path) -> tuple[str, float]:
    command = [
        "curl", "--silent", "--show-error", "--cacert", ca_file,
        "--http2", "--tlsv" + version, "--tls-max", version,
        "--max-time", "0.5", "--write-out",
        "\\n%{http_version} %{http_code} %{time_total} %{size_download}",
        f"https://localhost:{port}/",
    ]
    started = time.monotonic()
    try:
        result = subprocess.run(command, check=False, capture_output=True, timeout=1.5)
    except subprocess.TimeoutExpired as error:
        output.write_bytes(b"curl exceeded the 1.5 second process deadline\n")
        raise RuntimeError("load-time HTTP/2 request exceeded its finite deadline") from error
    elapsed_ms = (time.monotonic() - started) * 1000
    output.write_bytes(b"STDOUT\n" + result.stdout + b"\nSTDERR\n" + result.stderr)
    if result.returncode == 0:
        body, stats = result.stdout.rsplit(b"\n", 1)
        fields = stats.decode(errors="replace").split()
        if (body == BODY and fields[:2] == ["2", "200"] and
                len(fields) == 4 and fields[3] == str(len(BODY))):
            if elapsed_ms > 500:
                raise RuntimeError(f"HTTP/2 response arrived after load window: {elapsed_ms:.0f} ms")
            return "verified_http2_200_during_load", elapsed_ms
        raise RuntimeError(f"load-time curl returned unexpected response: {stats!r}")
    stderr = result.stderr.decode(errors="replace")
    if (result.returncode == 35 and
            ("SSL_ERROR_SYSCALL" in stderr or "Connection reset by peer" in stderr)):
        body, stats = result.stdout.rsplit(b"\n", 1)
        fields = stats.decode(errors="replace").split()
        if (body or len(fields) != 4 or fields[0] != "0" or fields[1] != "000" or
                fields[3] != "0"):
            raise RuntimeError(
                f"TLS refusal returned unexpected response data: {stats!r}"
            )
        if admitted != EFFECTIVE_CONNECTION_LIMIT or elapsed_ms > 500:
            raise RuntimeError(
                f"TLS refusal did not occur promptly at the measured admission cap: "
                f"admitted={admitted} cap={EFFECTIVE_CONNECTION_LIMIT} "
                f"elapsed_ms={elapsed_ms:.0f}"
            )
        return "request_not_accepted_at_measured_cap_tls_reset_exit_35", elapsed_ms
    if (admitted != EFFECTIVE_CONNECTION_LIMIT or elapsed_ms > 500 or
            result.returncode not in (7, 52, 56)):
        raise RuntimeError(
            f"load-time request failed before measured admission cap: {result.returncode}; "
            f"admitted={admitted} cap={EFFECTIVE_CONNECTION_LIMIT} elapsed_ms={elapsed_ms:.0f}"
        )
    return f"request_not_accepted_at_measured_cap_exit_{result.returncode}", elapsed_ms


def stop_server(process: subprocess.Popen[str], reader: threading.Thread) -> int:
    if process.poll() is None:
        try:
            if process.stdin is not None:
                process.stdin.write("stop\n")
                process.stdin.flush()
                process.stdin.close()
            process.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    if reader.ident is not None:
        reader.join(timeout=2)
    return process.returncode if process.returncode is not None else -1


def peer_rows(path: Path, peers: list[Peer]) -> None:
    with path.open("w", encoding="utf-8") as output:
        output.write(
            "index\ttype\tadmission\tadmission_observed_ms\tclose_kind\t"
            "close_ms\tfirst_data_hex\n"
        )
        for peer in peers:
            output.write(
                f"{peer.index}\t{peer.kind}\t{peer.admission}\t"
                f"{peer.admission_observed_ms}\t{peer.close_kind}\t"
                f"{peer.close_ms}\t{peer.first_data_hex}\n"
            )


def one_case(binary: Path, provider: str, version: str, cert: str, key: str,
             ca_file: str, root_log: Path) -> dict[str, object]:
    case_id = f"{provider}-tls{version.replace('.', '')}-{datetime.now(timezone.utc):%Y%m%dT%H%M%S}-{os.getpid()}"
    raw_dir = root_log / case_id
    raw_dir.mkdir(parents=True)
    (raw_dir / "configuration.txt").write_text(
        f"provider={provider}\ntls_version={version}\n"
        f"handshake_timeout_ms={HANDSHAKE_TIMEOUT_MS}\n"
        f"scheduler_margin_ms={SCHEDULER_MARGIN_MS}\n"
        f"listener_max_connections={MAX_CONNECTIONS}\n"
        f"effective_admission_limit={EFFECTIVE_CONNECTION_LIMIT}\n"
        "limit_source=server/src/Http2.Server.Async.Admission.inc:"
        "THttp2AsyncServer.ConnectionNew reserves before inherited ConnectionNew; "
        "server/src/Http2.Server.Async.Counters.pas:NewConnectionAdmission uses an "
        "atomic active-claim count; zero means unlimited\n"
        f"silent_peers={SILENT_PEERS}\npartial_client_hello_peers={PARTIAL_PEERS}\n",
        encoding="utf-8",
    )
    process = None
    reader = None
    peers: list[Peer] = []
    result: dict[str, object] = {}
    try:
        process, port, reader, events = start_server(
            binary, provider, cert, key, version, raw_dir
        )
        result["port"] = port
        with (raw_dir / "samples.tsv").open("w", encoding="utf-8") as samples:
            samples.write("monotonic_s\trss_kib\tcpu_seconds\tfd_count\tactive_peers\n")
            accepted_before_warmup = server_accepted_count(process, events)
            warmup_ms = http2_get(port, version, ca_file) * 1000
            accepted_after_warmup = server_accepted_count(process, events)
            if accepted_after_warmup != accepted_before_warmup + 1:
                raise RuntimeError(
                    "warmup HTTP/2 request did not add one accepted connection: "
                    f"before={accepted_before_warmup} after={accepted_after_warmup}"
                )
            baseline, warm_settle_seconds = settle_fds(
                process, peers, samples, target=None
            )
            baseline_accepted = accepted_after_warmup
            result["warmup_http2_ms"] = warmup_ms
            result["accepted_before_warmup"] = accepted_before_warmup
            result["accepted_after_warmup"] = accepted_after_warmup
            result["warm_settle_seconds"] = warm_settle_seconds
            peak_sample = baseline
            initial_peers = EFFECTIVE_CONNECTION_LIMIT
            for index in range(initial_peers):
                kind = "silent_tcp" if index % 2 == 0 else "partial_client_hello"
                peers.append(make_peer(port, index, kind))
            peak_sample = observe_window(process, peers, samples, peak_sample,
                                         ADMISSION_OBSERVE_MS)
            accepted_at_limit = server_accepted_count(process, events)
            admission_snapshot = time.monotonic()
            admitted = accepted_at_limit - baseline_accepted
            if admitted != initial_peers:
                raise RuntimeError(
                    f"first wave admitted {admitted} of {initial_peers} peers"
                )
            for peer in peers:
                if peer.sock is None or peer.close_kind != "open":
                    raise RuntimeError(
                        f"first wave peer {peer.index} closed before timeout: {peer.close_kind}"
                    )
                peer.admission = "admitted"
                peer.admission_observed_ms = round(
                    (admission_snapshot - peer.started) * 1000
                )
            excess_start = len(peers)
            for index in range(excess_start, excess_start + SILENT_PEERS):
                kind = "silent_tcp" if (index - excess_start) % 2 == 0 else "partial_client_hello"
                peers.append(make_peer(port, index, kind))
            peak_sample = observe_window(
                process, peers[excess_start:], samples, peak_sample,
                ADMISSION_OBSERVE_MS,
            )
            accepted_after_excess = server_accepted_count(process, events)
            excess_snapshot = time.monotonic()
            for peer in peers[excess_start:]:
                peer.admission_observed_ms = round(
                    (excess_snapshot - peer.started) * 1000
                )
                if peer.admission == "tcp_connection_refused":
                    peer.admission = "tcp_connection_refused"
                elif peer.close_kind in ("eof", "server_reset"):
                    peer.admission = "server_closed_during_capacity_observation"
                elif not peer.tcp_connected:
                    peer.admission = "peer_error_before_capacity_observation"
                elif peer.sock is None:
                    peer.admission = "peer_error_before_capacity_observation"
                else:
                    peer.admission = "still_open_at_capacity_observation"
                    peer.close_kind = "client_closed_after_capacity_observation"
                    peer.close_ms = round((excess_snapshot - peer.started) * 1000)
                if peer.sock is not None:
                    peer.sock.close()
                    peer.sock = None
            peer_rows(raw_dir / "peers.tsv", peers)
            tcp_connected = sum(peer.tcp_connected for peer in peers)
            not_admitted = len(peers) - admitted
            early_client_refusals = sum(
                peer.admission == "tcp_connection_refused" for peer in peers
            )
            excess_client_refusals = sum(
                peer.admission == "tcp_connection_refused"
                for peer in peers[excess_start:]
            )
            server_closed_excess = sum(
                peer.admission == "server_closed_during_capacity_observation"
                for peer in peers[excess_start:]
            )
            server_reset_excess = sum(
                peer.admission == "server_closed_during_capacity_observation" and
                peer.close_kind == "server_reset"
                for peer in peers[excess_start:]
            )
            server_eof_excess = sum(
                peer.admission == "server_closed_during_capacity_observation" and
                peer.close_kind == "eof"
                for peer in peers[excess_start:]
            )
            client_closed_excess = sum(
                peer.admission == "still_open_at_capacity_observation"
                for peer in peers[excess_start:]
            )
            peer_error_excess = sum(
                peer.admission == "peer_error_before_capacity_observation"
                for peer in peers[excess_start:]
            )
            if peer_error_excess:
                raise RuntimeError(
                    f"{peer_error_excess} excess peers failed before capacity classification"
                )
            open_at_load = sum(peer.sock is not None for peer in peers)
            result["admitted"] = admitted
            result["not_admitted"] = not_admitted
            result["server_closed_excess"] = server_closed_excess
            result["server_reset_excess"] = server_reset_excess
            result["server_eof_excess"] = server_eof_excess
            result["client_closed_excess"] = client_closed_excess
            result["excess_client_refusals"] = excess_client_refusals
            result["peer_error_excess"] = peer_error_excess
            result["tcp_connected"] = tcp_connected
            result["early_client_refusals"] = early_client_refusals
            result["open_during_load"] = open_at_load
            if admitted > EFFECTIVE_CONNECTION_LIMIT:
                raise RuntimeError(
                    f"measured admission {admitted} exceeds configured effective limit "
                    f"{EFFECTIVE_CONNECTION_LIMIT}"
                )
            if admitted != EFFECTIVE_CONNECTION_LIMIT:
                raise RuntimeError(
                    f"load did not show expected admission accounting: "
                    f"server_admitted={admitted}/{EFFECTIVE_CONNECTION_LIMIT} "
                    f"tcp_connected={tcp_connected} not_admitted={not_admitted} "
                    f"server_closed_excess={server_closed_excess} "
                    f"early_client_refusals={early_client_refusals}"
                )
            if accepted_after_excess != accepted_at_limit:
                raise RuntimeError(
                    f"listener admitted excess peers at its cap: before={accepted_at_limit} "
                    f"after={accepted_after_excess}"
                )
            if client_closed_excess:
                raise RuntimeError(
                    f"{client_closed_excess} excess peers remained open after the "
                    f"{ADMISSION_OBSERVE_MS} ms capacity-refusal window; they were "
                    "closed by the probe and are not counted as server refusals"
                )
            before_load_request = server_accepted_count(process, events)
            load_outcome, load_request_ms = during_load_request(
                port, version, ca_file, admitted, raw_dir / "request-during-load.txt"
            )
            result["request_during_load"] = load_outcome
            result["request_during_load_ms"] = load_request_ms
            accepted_after_load_request = server_accepted_count(process, events)
            load_request_delta = accepted_after_load_request - before_load_request
            if load_outcome == "verified_http2_200_during_load" and load_request_delta != 1:
                raise RuntimeError(
                    f"successful load request accepted-count delta is {load_request_delta}, expected 1"
                )
            if load_outcome.startswith("request_not_accepted") and load_request_delta != 0:
                raise RuntimeError(
                    f"non-acceptance response changed accepted count by {load_request_delta}, expected 0"
                )
            result["request_during_load_accepted_delta"] = load_request_delta
            with (raw_dir / "load-request.txt").open("w", encoding="utf-8") as output:
                output.write(load_outcome + "\n")
            peak_sample, _ = hold_and_measure(
                process, peers, samples, peak_sample
            )
            result["peak_rss_kib"] = peak_sample[0]
            result["peak_cpu_seconds"] = peak_sample[1]
            result["peak_fd_count"] = peak_sample[2]
            if any(peer.sock is not None for peer in peers):
                still_open = [peer.index for peer in peers if peer.sock is not None]
                raise RuntimeError(f"handshake peers exceeded timeout and margin: {still_open}")
            timed_out = [
                p for p in peers
                if p.admission == "admitted" and
                p.close_kind in ("eof", "server_reset") and
                HANDSHAKE_TIMEOUT_MS - 100 <= p.close_ms <=
                HANDSHAKE_TIMEOUT_MS + SCHEDULER_MARGIN_MS
            ]
            early_server_data = [p.index for p in peers
                                 if p.admission == "admitted" and p.first_data_hex]
            if early_server_data:
                raise RuntimeError(f"incomplete handshake peers received server data: {early_server_data}")
            if len(timed_out) != admitted:
                raise RuntimeError(
                    f"accepted peers did not all close by timeout: eof={len(timed_out)} "
                    f"admitted={admitted}"
                )
            peer_rows(raw_dir / "peers.tsv", peers)
            request_ms = http2_get(port, version, ca_file)
            result["recovery_http2_ms"] = request_ms * 1000
            recovery_accepted = server_accepted_count(process, events)
            if recovery_accepted != accepted_after_load_request + 1:
                raise RuntimeError(
                    f"recovery request did not add one accepted connection: "
                    f"before={accepted_after_load_request} after={recovery_accepted}"
                )
            settled, settle_seconds = settle_fds(
                process, peers, samples, target=baseline[2]
            )
            result["settle_seconds"] = settle_seconds
            if settled[2] != baseline[2]:
                raise RuntimeError(
                    f"file descriptor count did not return to warmed baseline: "
                    f"baseline={baseline[2]} settled={settled[2]}"
                )
            result["baseline_rss_kib"] = baseline[0]
            result["settled_rss_kib"] = settled[0]
            result["baseline_cpu_seconds"] = baseline[1]
            result["peak_cpu_seconds"] = peak_sample[1]
            result["settled_cpu_seconds"] = settled[1]
            result["baseline_fd_count"] = baseline[2]
            result["peak_fd_count"] = peak_sample[2]
            result["settled_fd_count"] = settled[2]
            result["raw_dir"] = str(raw_dir)
            close_times = [peer.close_ms for peer in timed_out]
            summary = (
                f"provider={provider}\ntls_version={version}\n"
                f"admitted={admitted}\nnot_admitted_during_observation={not_admitted}\n"
                f"server_closed_excess={server_closed_excess}\n"
                f"server_reset_excess={server_reset_excess}\n"
                f"server_eof_excess={server_eof_excess}\n"
                f"client_closed_excess={client_closed_excess}\n"
                f"excess_client_refusals={excess_client_refusals}\n"
                f"peer_error_excess={peer_error_excess}\n"
                f"tcp_connected={tcp_connected}\nearly_client_refusals={early_client_refusals}\n"
                f"timeout_close_count={len(timed_out)}\n"
                f"timeout_close_min_ms={min(close_times)}\n"
                f"timeout_close_max_ms={max(close_times)}\n"
                f"request_during_load={load_outcome}\n"
                f"accepted_before_warmup={accepted_before_warmup}\n"
                f"accepted_after_warmup={accepted_after_warmup}\n"
                f"accepted_at_limit={accepted_at_limit}\n"
                f"first_wave_admitted={admitted}\n"
                f"accepted_after_excess={accepted_after_excess}\n"
                f"excess_wave_accepted_delta={accepted_after_excess - accepted_at_limit}\n"
                f"accepted_before_load_request={before_load_request}\n"
                f"accepted_after_load_request={accepted_after_load_request}\n"
                f"load_request_accepted_delta={load_request_delta}\n"
                f"accepted_after_recovery={recovery_accepted}\n"
                f"recovery_request_accepted_delta={recovery_accepted - accepted_after_load_request}\n"
                f"warm_settle_seconds={warm_settle_seconds:.3f}\n"
                f"postload_settle_seconds={settle_seconds:.3f}\n"
                f"warmup_http2_ms={warmup_ms:.2f}\n"
                f"request_during_load_ms={load_request_ms:.2f}\n"
                f"recovery_http2_ms={request_ms * 1000:.2f}\n"
                f"rss_kib_baseline_peak_settled={baseline[0]}/{peak_sample[0]}/{settled[0]}\n"
                f"cpu_seconds_baseline_peak_settled={baseline[1]:.3f}/{peak_sample[1]:.3f}/{settled[1]:.3f}\n"
                f"fd_count_baseline_peak_settled={baseline[2]}/{peak_sample[2]}/{settled[2]}\n"
            )
            (raw_dir / "summary.txt").write_text(summary, encoding="utf-8")
            return result
    except Exception as error:
        raise RuntimeError(f"{error}; raw results: {raw_dir}") from error
    finally:
        for peer in peers:
            if peer.sock is not None:
                try:
                    peer.sock.close()
                except OSError:
                    pass
                peer.close_kind = "closed_by_probe_cleanup"
                peer.sock = None
        if peers:
            peer_rows(raw_dir / "peers.tsv", peers)
        if process is not None and reader is not None:
            return_code = stop_server(process, reader)
            (raw_dir / "server-exit.txt").write_text(f"{return_code}\n", encoding="utf-8")
            if return_code != 0:
                raise RuntimeError(f"ProviderLive exited with status {return_code}; raw data: {raw_dir}")


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print("usage: slow_handshakes.py CERTIFICATE KEY [openssl|tlslib]", file=sys.stderr)
        return 2
    cert, key = (str(Path(arg).resolve()) for arg in sys.argv[1:3])
    ca_file = str(Path(cert).with_name("ca.crt"))
    if not Path(ca_file).is_file():
        raise SystemExit(f"trusted CA file is absent: {ca_file}")
    providers = [sys.argv[3]] if len(sys.argv) == 4 else ["openssl", "tlslib"]
    if any(provider not in {"openssl", "tlslib"} for provider in providers):
        raise SystemExit("provider must be openssl or tlslib")
    binary = provider_binary()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise SystemExit(
            f"ProviderLive binary is absent or not executable: {binary}; "
            "build the server probe first or set PROVIDER_LIVE_BINARY"
        )
    log_root = Path(os.environ.get("VALIDATION_LOG_DIR", ROOT / "bin/validation/logs"))
    log_root.mkdir(parents=True, exist_ok=True)
    print(f"provider_live_binary={binary}")
    print(f"raw_results={log_root}")
    print(f"context_default_handshake_timeout_ms=0 (disabled); configured_test_timeout_ms={HANDSHAKE_TIMEOUT_MS}")
    print(f"configured_listener_limit={MAX_CONNECTIONS}; effective_admission_limit={EFFECTIVE_CONNECTION_LIMIT}")
    failures = []
    for provider in providers:
        for version in ("1.2", "1.3"):
            try:
                result = one_case(binary, provider, version, cert, key, ca_file, log_root)
                print(
                    f"PASS {provider} TLS {version}: admitted={result['admitted']} "
                    f"not-admitted={result['not_admitted']} "
                    f"during-load={result['request_during_load']} "
                    f"recovery-h2={result['recovery_http2_ms']:.2f}ms "
                    f"RSS KiB baseline/peak/settled="
                    f"{result['baseline_rss_kib']}/{result['peak_rss_kib']}/"
                    f"{result['settled_rss_kib']} CPU seconds baseline/peak/settled="
                    f"{result['baseline_cpu_seconds']:.2f}/{result['peak_cpu_seconds']:.2f}/"
                    f"{result['settled_cpu_seconds']:.2f} "
                    f"FD baseline/peak/settled="
                    f"{result['baseline_fd_count']}/{result['peak_fd_count']}/"
                    f"{result['settled_fd_count']} raw={result['raw_dir']}"
                )
            except Exception as error:
                failures.append(f"{provider} TLS {version}: {error}")
                print(f"FAIL {failures[-1]}", file=sys.stderr)
    if failures:
        return 1
    print(f"PASS concurrent incomplete TLS handshakes: {2 * len(providers)}/{2 * len(providers)} provider/version cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
