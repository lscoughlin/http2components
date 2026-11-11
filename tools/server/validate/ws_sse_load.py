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
import re
import subprocess
import sys
import time

KEY = "dGhlIHNhbXBsZSBub25jZQ=="


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
                if head.startswith(b"HTTP/1.1 101"):
                    return (r, w)
                w.close()
            except (OSError, asyncio.TimeoutError, asyncio.IncompleteReadError):
                if w is not None:
                    w.close()
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
                if head.startswith(b"HTTP/1.1 200"):
                    return (r, w)
                w.close()
            except (OSError, asyncio.TimeoutError, asyncio.IncompleteReadError):
                if w is not None:
                    w.close()
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

    while time.monotonic() < end:
        tasks.append(asyncio.create_task(one()))
        nxt += interval
        await asyncio.sleep(max(0.0, nxt - time.monotonic()))
    await asyncio.gather(*tasks)


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
    ws = await asyncio.gather(*[open_ws(host, wsport, sem) for _ in range(n)])
    sse = await asyncio.gather(*[open_sse(host, sseport, sem) for _ in range(n)])
    ok_ws = sum(1 for x in ws if x)
    ok_sse = sum(1 for x in sse if x)
    print(f"opened {ok_ws}/{n} WebSocket sessions and {ok_sse}/{n} event streams "
          f"in {time.monotonic() - t0:.1f} s", flush=True)
    lat = []
    complete = False
    try:
        await asyncio.sleep(2)
        open_ws_rss, open_sse_rss = ps(wspid), ps(ssepid)
        print(f"memory per WebSocket session: {(open_ws_rss[0] - base_ws[0]) * 1024 / max(ok_ws, 1):.0f} octets")
        print(f"memory per event stream: {(open_sse_rss[0] - base_sse[0]) * 1024 / max(ok_sse, 1):.0f} octets")
        c0w, c0s = ps(wspid)[1], ps(ssepid)[1]
        run_start = time.monotonic()
        await requests(host, sseport, window, rate, lat)
        elapsed = time.monotonic() - run_start
        c1w, c1s = ps(wspid)[1], ps(ssepid)[1]
        lat.sort()
        fin = [x for x in lat if x != float("inf")]
        p = lambda q: fin[min(len(fin) - 1, int(len(fin) * q))] if fin else float("nan")
        print(f"ordinary requests: {len(lat)} sent, {len(fin)} passed, {len(lat) - len(fin)} failed, "
              f"p50 {p(0.5):.1f} ms, p99 {p(0.99):.1f} ms, max {fin[-1] if fin else float('nan'):.1f} ms")
        print(f"server CPU over {elapsed:.1f} s: WebSocket server {(c1w - c0w) / elapsed * 100:.1f}%, "
              f"event-stream server {(c1s - c0s) / elapsed * 100:.1f}% of one core")
        complete = ok_ws == n and ok_sse == n and len(fin) == len(lat) and len(lat) > 0
    finally:
        for pair in ws + sse:
            if pair:
                pair[1].close()
        closed = 0
        for pair in ws + sse:
            if pair:
                try:
                    await asyncio.wait_for(pair[1].wait_closed(), 2)
                    closed += 1
                except (asyncio.TimeoutError, OSError):
                    pass
        print(f"cleanup: {closed}/{ok_ws + ok_sse} client sockets closed")
    if not complete or closed != ok_ws + ok_sse:
        raise SystemExit(1)
    print(f"PASS load run: {len(lat)} requests; runtime {time.monotonic() - t0:.1f} s")


if __name__ == "__main__":
    asyncio.run(main())
