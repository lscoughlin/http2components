#!/usr/bin/env python3
"""Load run: idle WebSocket sessions and open event streams with steady requests.

The script starts nothing but the two clients of the load. A caller starts the
`ws_echo` and `sse_replay` example programs first, and raises
the file limit (`ulimit -n 60000`).

It opens N WebSocket sessions on the first server and N event streams on the second
(path /hold), both over HTTP/1.1 on plain sockets. Then it sends ordinary requests
at a steady rate for the window and reports the latency percentiles. It reads the
resident memory and the CPU time of both server processes before and after.

Usage: ws_sse_load.py HOST WSPORT SSEPORT N WINDOW RATE WSPID SSEPID
"""
import asyncio
import base64
import hashlib
import os
import re
import subprocess
import sys
import time

KEY = "dGhlIHNhbXBsZSBub25jZQ=="
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
READ_BYTES = 16384


def parse_response_head(head: bytes):
    """Parse the status line and headers of one complete HTTP response head."""
    lines = head.removesuffix(b"\r\n\r\n").split(b"\r\n")
    if not lines or not lines[0].startswith(b"HTTP/1.1 "):
        raise RuntimeError("response did not use HTTP/1.1")
    fields = lines[0].split(b" ", 2)
    if len(fields) < 2 or not fields[1].isdigit():
        raise RuntimeError("response status line is malformed")
    headers = {}
    for line in lines[1:]:
        name, separator, value = line.partition(b":")
        if not separator or not name:
            raise RuntimeError("response header line is malformed")
        headers.setdefault(name.strip().lower(), []).append(value.strip())
    return int(fields[1]), headers


def header_tokens(headers, name):
    return {token.strip().lower()
            for value in headers.get(name, [])
            for token in value.split(b",")}


def validate_ws_upgrade(head: bytes):
    status, headers = parse_response_head(head)
    expected = base64.b64encode(hashlib.sha1(
        (KEY + WS_GUID).encode("ascii")).digest())
    if status != 101:
        raise RuntimeError("WebSocket response status was not 101")
    if b"websocket" not in header_tokens(headers, b"upgrade"):
        raise RuntimeError("WebSocket response omitted Upgrade: websocket")
    if b"upgrade" not in header_tokens(headers, b"connection"):
        raise RuntimeError("WebSocket response omitted Connection: Upgrade")
    if headers.get(b"sec-websocket-accept") != [expected]:
        raise RuntimeError("WebSocket response has an invalid Sec-WebSocket-Accept")


def validate_sse_response(head: bytes):
    status, headers = parse_response_head(head)
    content_types = headers.get(b"content-type", [])
    media_type = content_types[0].split(b";", 1)[0].strip().lower() if content_types else b""
    if status != 200 or media_type != b"text/event-stream":
        raise RuntimeError("SSE response must be HTTP 200 text/event-stream")


def masked_ws_frame(opcode: int, payload: bytes) -> bytes:
    """Build one masked WebSocket client control frame."""
    if len(payload) > 125:
        raise ValueError("WebSocket control payload exceeds 125 octets")
    mask = os.urandom(4)
    encoded = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return bytes((0x80 | opcode, 0x80 | len(payload))) + mask + encoded


class WebSocketHold:
    """Discard bounded server frames, answer Ping, and reject Close or EOF."""
    def __init__(self, writer, label):
        self.writer = writer
        self.label = label
        self.buffer = bytearray()
        self.remaining = None
        self.opcode = None
        self.ping_payload = bytearray()

    async def feed(self, chunk):
        self.buffer.extend(chunk)
        while True:
            if self.remaining is not None:
                take = min(self.remaining, len(self.buffer))
                if self.opcode == 0x9:
                    self.ping_payload.extend(self.buffer[:take])
                del self.buffer[:take]
                self.remaining -= take
                if self.remaining:
                    return
                if self.opcode == 0x9:
                    self.writer.write(masked_ws_frame(0xA, bytes(self.ping_payload)))
                    await self.writer.drain()
                self.remaining = None
                self.opcode = None
                self.ping_payload.clear()
                continue
            if len(self.buffer) < 2:
                return
            first, second = self.buffer[0], self.buffer[1]
            opcode = first & 0x0F
            if first & 0x70:
                raise RuntimeError(f"{self.label}: server set a reserved WebSocket bit")
            if second & 0x80:
                raise RuntimeError(f"{self.label}: server sent a masked WebSocket frame")
            if opcode not in (0x0, 0x1, 0x2, 0x8, 0x9, 0xA):
                raise RuntimeError(f"{self.label}: server sent reserved WebSocket opcode {opcode}")
            length = second & 0x7F
            header_size = 2
            if length == 126:
                header_size += 2
                if len(self.buffer) < header_size:
                    return
                length = int.from_bytes(self.buffer[2:4], "big")
            elif length == 127:
                header_size += 8
                if len(self.buffer) < header_size:
                    return
                length = int.from_bytes(self.buffer[2:10], "big")
                if length & (1 << 63):
                    raise RuntimeError(f"{self.label}: invalid WebSocket frame length")
            control = opcode >= 0x8
            if control and (not first & 0x80 or length > 125):
                raise RuntimeError(f"{self.label}: invalid WebSocket control frame")
            if opcode == 0x8:
                raise RuntimeError(f"{self.label}: server sent a WebSocket Close frame")
            del self.buffer[:header_size]
            if length == 0:
                if opcode == 0x9:
                    self.writer.write(masked_ws_frame(0xA, b""))
                    await self.writer.drain()
                continue
            self.remaining = length
            self.opcode = opcode
            self.ping_payload.clear()


async def close_writer(writer):
    writer.close()
    try:
        await asyncio.wait_for(writer.wait_closed(), 2)
        return True
    except (asyncio.TimeoutError, OSError):
        return False


async def tracked_open(opener, host, port, sem, opened):
    """Keep each successful connection reachable while other opens wait."""
    pair = await opener(host, port, sem)
    if pair is not None:
        opened.append(pair)
    return pair


async def monitor_sse(reader, label):
    while True:
        chunk = await reader.read(READ_BYTES)
        if not chunk:
            raise RuntimeError(f"{label}: peer closed during the hold window")


async def monitor_ws(reader, writer, label):
    protocol = WebSocketHold(writer, label)
    while True:
        chunk = await reader.read(READ_BYTES)
        if not chunk:
            raise RuntimeError(f"{label}: peer closed during the hold window")
        await protocol.feed(chunk)


async def monitor_sessions(ws, sse):
    tasks = []
    tasks.extend(asyncio.create_task(monitor_ws(reader, writer, f"WebSocket {index}"))
                 for index, (reader, writer) in enumerate(ws) if writer is not None)
    tasks.extend(asyncio.create_task(monitor_sse(reader, f"SSE {index}"))
                 for index, (reader, writer) in enumerate(sse) if writer is not None)
    try:
        if tasks:
            await asyncio.gather(*tasks)
        else:
            await asyncio.Future()
    finally:
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)


async def run_requests_while_live(host, port, window, rate, lat, monitor_task):
    request_task = asyncio.create_task(requests(host, port, window, rate, lat))
    try:
        done, _ = await asyncio.wait((request_task, monitor_task),
                                     return_when=asyncio.FIRST_COMPLETED)
        if monitor_task in done:
            await monitor_task
            raise RuntimeError("liveness monitors ended before the load window")
        await request_task
        await asyncio.sleep(0)
        if monitor_task.done():
            await monitor_task
            raise RuntimeError("a held connection ended at the load window boundary")
    finally:
        if not request_task.done():
            request_task.cancel()
            await asyncio.gather(request_task, return_exceptions=True)


def cpu_seconds(value: str) -> float:
    """Parse ps TIME on Linux (HH:MM:SS) and BSD/macOS (MM:SS.hh)."""
    match = re.fullmatch(r"(?:(\d+)-(\d{1,2}):(\d{2}):(\d{2})|(\d{1,2}):(\d{2}):(\d{2})|(\d+):(\d{2})\.(\d+))", value)
    if not match:
        raise ValueError(f"unsupported ps CPU time: {value!r}")
    if match.group(1) is not None:
        days, hours, minutes, seconds = map(int, match.groups()[:4])
        return days * 86400 + hours * 3600 + minutes * 60 + seconds
    if match.group(5) is not None:
        hours, minutes, seconds = map(int, match.groups()[4:7])
        return hours * 3600 + minutes * 60 + seconds
    minutes, seconds = map(int, match.groups()[7:9])
    fraction = float("0." + match.group(10))
    return minutes * 60 + seconds + fraction


def ps(pid: int):
    result = subprocess.run(["ps", "-o", "rss=,time=", "-p", str(pid)],
                            capture_output=True, text=True, check=True)
    out = result.stdout.split()
    if len(out) != 2:
        raise RuntimeError(f"server process {pid} is absent or has invalid ps output")
    return int(out[0]), cpu_seconds(out[1])


async def open_ws(host, port, sem):
    async with sem:
        # a burst can pass the admission queue; the server answers 503 with Retry-After
        # and the client tries again, as the answer asks
        for _ in range(50):
            w = None
            try:
                r, w = await asyncio.wait_for(asyncio.open_connection(host, port), 5)
                w.write((f"GET /ws HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
                         f"Connection: Upgrade\r\nSec-WebSocket-Key: {KEY}\r\n"
                         f"Sec-WebSocket-Version: 13\r\n\r\n").encode())
                head = await asyncio.wait_for(r.readuntil(b"\r\n\r\n"), 5)
                status, _ = parse_response_head(head)
                if status == 503:
                    await close_writer(w)
                    await asyncio.sleep(0.05)
                    continue
                validate_ws_upgrade(head)
                return (r, w)
            except RuntimeError:
                if w is not None:
                    await close_writer(w)
                raise
            except (OSError, asyncio.TimeoutError, asyncio.IncompleteReadError):
                if w is not None:
                    await close_writer(w)
            except BaseException:
                if w is not None:
                    await asyncio.shield(close_writer(w))
                raise
            await asyncio.sleep(0.05)
        return None


async def open_sse(host, port, sem):
    async with sem:
        for _ in range(50):
            w = None
            try:
                r, w = await asyncio.wait_for(asyncio.open_connection(host, port), 5)
                w.write(f"GET /hold HTTP/1.1\r\nHost: {host}\r\n\r\n".encode())
                head = await asyncio.wait_for(r.readuntil(b"\r\n\r\n"), 5)
                status, _ = parse_response_head(head)
                if status == 503:
                    await close_writer(w)
                    await asyncio.sleep(0.05)
                    continue
                validate_sse_response(head)
                return (r, w)
            except RuntimeError:
                if w is not None:
                    await close_writer(w)
                raise
            except (OSError, asyncio.TimeoutError, asyncio.IncompleteReadError):
                if w is not None:
                    await close_writer(w)
            except BaseException:
                if w is not None:
                    await asyncio.shield(close_writer(w))
                raise
            await asyncio.sleep(0.05)
        return None


async def requests(host, port, window, rate, lat):
    end = time.monotonic() + window
    interval = 1.0 / rate
    nxt = time.monotonic()
    tasks = []

    async def one():
        t0 = time.monotonic()
        w = None
        try:
            r, w = await asyncio.wait_for(asyncio.open_connection(host, port), 5)
            w.write(f"GET /events HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n"
                    f"Last-Event-ID: 999\r\n\r\n".encode())
            response = await asyncio.wait_for(r.read(-1), 10)
            head, separator, body = response.partition(b"\r\n\r\n")
            headers = {}
            if separator:
                for line in head.split(b"\r\n")[1:]:
                    name, split, value = line.partition(b":")
                    if split:
                        headers[name.strip().lower()] = value.strip().lower()
            if (not separator or not head.startswith(b"HTTP/1.1 200 ") or
                    not headers.get(b"content-type", b"").startswith(b"text/event-stream")):
                raise RuntimeError("event request did not return HTTP 200 text/event-stream")
            if b"data:" not in body or b"\n\n" not in body:
                raise RuntimeError("event request returned no complete SSE event")
            lat.append((time.monotonic() - t0) * 1000.0)
        except Exception:
            lat.append(float("inf"))
        finally:
            if w is not None:
                w.close()
                try:
                    await asyncio.wait_for(w.wait_closed(), 2)
                except (asyncio.TimeoutError, OSError):
                    pass

    try:
        while time.monotonic() < end:
            tasks.append(asyncio.create_task(one()))
            nxt += interval
            await asyncio.sleep(max(0.0, nxt - time.monotonic()))
        await asyncio.gather(*tasks)
    finally:
        for task in tasks:
            if not task.done():
                task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)


async def main():
    if len(sys.argv) != 9:
        raise SystemExit(__doc__.split("Usage: ", 1)[1].splitlines()[0])
    host, wsport, sseport = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    n, window, rate = int(sys.argv[4]), float(sys.argv[5]), float(sys.argv[6])
    wspid, ssepid = int(sys.argv[7]), int(sys.argv[8])
    if not 0 < n <= 10000 or not 0 < window <= 3600 or not 0 < rate <= 10000:
        raise SystemExit("N and RATE must be in (0, 10000]; WINDOW must be in (0, 3600]")
    base_ws, base_sse = ps(wspid), ps(ssepid)
    sem = asyncio.Semaphore(200)
    t0 = time.monotonic()
    ws = []
    sse = []
    lat = []
    monitor_task = None
    ok_ws = ok_sse = 0
    complete = False
    closed = 0
    failure = None
    cleanup_failure = None
    try:
        ws_results = await asyncio.gather(
            *[tracked_open(open_ws, host, wsport, sem, ws) for _ in range(n)],
            return_exceptions=True)
        sse_results = await asyncio.gather(
            *[tracked_open(open_sse, host, sseport, sem, sse) for _ in range(n)],
            return_exceptions=True)
        ok_ws = len(ws)
        ok_sse = len(sse)
        print(f"opened {ok_ws}/{n} WebSocket sessions and {ok_sse}/{n} event streams "
              f"in {time.monotonic() - t0:.1f} s", flush=True)
        open_errors = [result for result in ws_results + sse_results
                       if isinstance(result, BaseException)]
        if open_errors:
            raise RuntimeError(f"connection setup failed: {open_errors[0]}")
        if ok_ws != n or ok_sse != n:
            raise RuntimeError("not all requested WebSocket and SSE connections opened")

        monitor_task = asyncio.create_task(monitor_sessions(ws, sse))
        await asyncio.sleep(2)
        open_ws_stats, open_sse_stats = ps(wspid), ps(ssepid)
        print(f"memory per WebSocket session: {(open_ws_stats[0] - base_ws[0]) * 1024 / ok_ws:.0f} octets")
        print(f"memory per event stream: {(open_sse_stats[0] - base_sse[0]) * 1024 / ok_sse:.0f} octets")
        c0w, c0s = ps(wspid)[1], ps(ssepid)[1]
        run_start = time.monotonic()
        await run_requests_while_live(host, sseport, window, rate, lat,
                                      monitor_task)
        elapsed = time.monotonic() - run_start
        c1w, c1s = ps(wspid)[1], ps(ssepid)[1]
        lat.sort()
        fin = [value for value in lat if value != float("inf")]
        percentile = lambda q: fin[min(len(fin) - 1, int(len(fin) * q))] if fin else float("nan")
        print(f"ordinary requests: {len(lat)} sent, {len(fin)} passed, "
              f"{len(lat) - len(fin)} failed, p50 {percentile(0.5):.1f} ms, "
              f"p99 {percentile(0.99):.1f} ms, max {fin[-1] if fin else float('nan'):.1f} ms")
        print(f"server CPU over {elapsed:.1f} s: WebSocket server "
              f"{(c1w - c0w) / elapsed * 100:.1f}%, event-stream server "
              f"{(c1s - c0s) / elapsed * 100:.1f}% of one core")
        complete = (ok_ws == n and ok_sse == n and len(fin) == len(lat)
                    and len(lat) > 0)
    except BaseException as error:
        failure = error
    finally:
        if monitor_task is not None:
            monitor_task.cancel()
            await asyncio.gather(monitor_task, return_exceptions=True)
        pairs = [pair for pair in ws + sse if pair]
        for _reader, writer in pairs:
            writer.close()
        close_results = await asyncio.gather(
            *[asyncio.wait_for(writer.wait_closed(), 2) for _reader, writer in pairs],
            return_exceptions=True)
        closed = sum(1 for result in close_results if not isinstance(result, BaseException))
        print(f"cleanup: {closed}/{len(pairs)} client sockets closed")
        try:
            disconnected_ws, disconnected_sse = ps(wspid), ps(ssepid)
            print(f"post-disconnect RSS: WebSocket {disconnected_ws[0]} KiB, "
                  f"SSE {disconnected_sse[0]} KiB; CPU {disconnected_ws[1]:.2f} s, "
                  f"{disconnected_sse[1]:.2f} s")
            await asyncio.sleep(2)
            settled_ws, settled_sse = ps(wspid), ps(ssepid)
            print(f"settled RSS after 2 s: WebSocket {settled_ws[0]} KiB, "
                  f"SSE {settled_sse[0]} KiB; CPU delta "
                  f"{settled_ws[1] - disconnected_ws[1]:.2f} s, "
                  f"{settled_sse[1] - disconnected_sse[1]:.2f} s")
        except BaseException as error:
            cleanup_failure = error
            print(f"cleanup sample failed: {error}")
    if failure is not None:
        raise failure
    if cleanup_failure is not None:
        raise cleanup_failure
    if not complete or closed != ok_ws + ok_sse:
        raise SystemExit(1)
    print(f"PASS load run: {len(lat)} requests; runtime {time.monotonic() - t0:.1f} s")


if __name__ == "__main__":
    asyncio.run(main())
