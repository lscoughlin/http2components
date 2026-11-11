#!/usr/bin/env python3
"""Independent HTTP/1.1 WebSocket echo checks for ws_echo.

Usage: ws_h1_client.py HOST PORT
"""
import base64
import hashlib
import os
import socket
import struct
import sys

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
KEY = base64.b64encode(os.urandom(16)).decode()
results = []


def record(name, ok, detail=""):
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + (f" ({detail})" if detail else ""))


def read_exact(sock, count, pending=None):
    data = bytearray()
    if pending:
        take = min(count, len(pending))
        data.extend(pending[:take])
        del pending[:take]
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise ConnectionError("peer closed before the full WebSocket frame arrived")
        data.extend(chunk)
    return bytes(data)


def read_frame(sock, pending):
    first, second = read_exact(sock, 2, pending)
    length = second & 0x7f
    if length == 126:
        length = struct.unpack(">H", read_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", read_exact(sock, 8))[0]
    return first & 0x0f, read_exact(sock, length, pending)


def send_frame(sock, opcode, payload):
    mask = os.urandom(4)
    length = len(payload)
    head = bytes([0x80 | opcode])
    if length < 126:
        head += bytes([0x80 | 0x80 | length])
    elif length < 65536:
        head += bytes([0x80 | 0x80 | 126]) + struct.pack(">H", length)
    else:
        head += bytes([0x80 | 0x80 | 127]) + struct.pack(">Q", length)
    sock.sendall(head + mask + bytes(value ^ mask[i % 4] for i, value in enumerate(payload)))


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    host, port = sys.argv[1], int(sys.argv[2])
    sock = socket.create_connection((host, port), timeout=5)
    sock.settimeout(5)
    try:
        request = (f"GET /ws HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
                   f"Connection: Upgrade\r\nSec-WebSocket-Key: {KEY}\r\n"
                   "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: echo\r\n\r\n")
        sock.sendall(request.encode())
        response = bytearray()
        while b"\r\n\r\n" not in response:
            if len(response) > 65536:
                raise RuntimeError("WebSocket response headers exceed 64 KiB")
            chunk = sock.recv(4096)
            if not chunk:
                raise ConnectionError("peer closed before completing WebSocket response headers")
            response.extend(chunk)
        header_bytes, _, remainder = bytes(response).partition(b"\r\n\r\n")
        headers = header_bytes.decode("latin1").split("\r\n")
        fields = {}
        for line in headers[1:]:
            name, separator, value = line.partition(":")
            if separator:
                fields[name.strip().lower()] = value.strip()
        expected = base64.b64encode(hashlib.sha1((KEY + GUID).encode()).digest()).decode()
        record("HTTP/1.1 WebSocket upgrade", headers[0].startswith("HTTP/1.1 101 ") and
               fields.get("sec-websocket-accept") == expected and
               fields.get("sec-websocket-protocol", "").lower() == "echo")
        pending = bytearray(remainder)
        send_frame(sock, 1, b"hello over http/1.1")
        opcode, payload = read_frame(sock, pending)
        record("text echo", opcode == 1 and payload == b"hello over http/1.1")
        send_frame(sock, 2, b"\x00\x01\xff")
        opcode, payload = read_frame(sock, pending)
        record("binary echo", opcode == 2 and payload == b"\x00\x01\xff")
        send_frame(sock, 9, b"ping")
        opcode, payload = read_frame(sock, pending)
        record("ping and pong", opcode == 10 and payload == b"ping")
        send_frame(sock, 8, struct.pack(">H", 1000))
        opcode, payload = read_frame(sock, pending)
        record("close handshake", opcode == 8 and payload[:2] == struct.pack(">H", 1000))
    except Exception as exc:
        record("HTTP/1.1 WebSocket checks", False, str(exc))
    finally:
        sock.close()
    print(f"SUMMARY checks={len(results)} passed={sum(results)} failed={len(results) - sum(results)}")
    return 0 if all(results) and len(results) == 5 else 1


if __name__ == "__main__":
    raise SystemExit(main())
