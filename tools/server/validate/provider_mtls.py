#!/usr/bin/env python3
"""Check independent client identity handling for both TLS providers."""
import os
import re
import select
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SOURCE = "test/integration/server/tls/Http2.Server.ProviderLive.pas"
BODY = b"provider-server-ok\n"
PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"


def run(command, *, timeout=30, **kwargs):
    result = subprocess.run(command, cwd=ROOT, check=False, timeout=timeout,
                            capture_output=True, **kwargs)
    if result.returncode:
        stdout = result.stdout.decode(errors="replace") if isinstance(result.stdout, bytes) else result.stdout
        stderr = result.stderr.decode(errors="replace") if isinstance(result.stderr, bytes) else result.stderr
        raise RuntimeError(f"command failed with exit {result.returncode}: {command!r}\n{stdout}{stderr}")
    return result


def compile_probe():
    run([sys.executable, "tools/build.py", "compile:server:probe", SOURCE], timeout=180)
    target = os.environ.get("TARGET")
    if not target:
        cpu = run([os.environ.get("FPC", "fpc"), "-iTP"], text=True).stdout.strip()
        os_name = run([os.environ.get("FPC", "fpc"), "-iTO"], text=True).stdout.strip()
        target = f"{cpu}-{os_name}"
    profile = os.environ.get("PROFILE", "debug" if os.environ.get("DEBUG") else "default")
    binary = ROOT / "bin" / target / profile / "integration-test" / "programs" / Path(SOURCE).stem
    if not binary.is_file():
        raise RuntimeError(f"probe compiler did not produce {binary}")
    return binary


def wait_ready(process, output_lines):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        ready, _, _ = select.select([process.stdout], [], [], deadline - time.monotonic())
        if not ready:
            break
        line = process.stdout.readline()
        if not line:
            if process.poll() is not None:
                raise RuntimeError(f"provider server exited {process.returncode}")
            continue
        output_lines.append(line)
        match = re.fullmatch(r"READY port (\d+)\s*", line)
        if match:
            return int(match.group(1))
        print(line, end="")
    raise TimeoutError("provider server did not report a port in 10 seconds")


def frame(kind, flags, stream, payload=b""):
    return len(payload).to_bytes(3, "big") + bytes((kind, flags)) + struct.pack("!I", stream) + payload


def request_bytes(port):
    authority = f"localhost:{port}".encode("ascii")
    # Indexed :method GET, :scheme https, :path /, then literal :authority.
    block = b"\x82\x87\x84\x01" + bytes((len(authority),)) + authority
    return PREFACE + frame(4, 0, 0) + frame(1, 5, 1, block)


def recv_frame(sock):
    header = read_exact(sock, 9)
    length = int.from_bytes(header[:3], "big")
    kind, flags = header[3], header[4]
    stream = struct.unpack("!I", header[5:])[0] & 0x7fffffff
    return kind, flags, stream, read_exact(sock, length)


def read_exact(sock, size):
    chunks = bytearray()
    while len(chunks) < size:
        part = sock.recv(size - len(chunks))
        if not part:
            raise EOFError("TLS peer closed")
        chunks.extend(part)
    return bytes(chunks)


def make_context(ca, identity):
    context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH, cafile=str(ca))
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.set_alpn_protocols(["h2"])
    if identity:
        context.load_cert_chain(str(identity[0]), str(identity[1]))
    return context


def connect(port, version, ca, identity):
    context = make_context(ca, identity)
    context.minimum_version = context.maximum_version = (
        ssl.TLSVersion.TLSv1_2 if version == "1.2" else ssl.TLSVersion.TLSv1_3)
    raw = socket.create_connection(("127.0.0.1", port), timeout=5)
    raw.settimeout(5)
    return context.wrap_socket(raw, server_hostname="localhost")


def positive_request(port, version, ca, identity):
    with connect(port, version, ca, identity) as tls:
        if tls.selected_alpn_protocol() != "h2":
            raise RuntimeError("positive peer did not negotiate ALPN h2")
        tls.sendall(request_bytes(port))
        body = bytearray()
        status_200 = False
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            tls.settimeout(max(0.1, deadline - time.monotonic()))
            kind, flags, stream, payload = recv_frame(tls)
            if kind == 1 and stream == 1:
                # A table-size update can precede static index 8 (:status 200).
                index = 0
                while index < len(payload) and payload[index] & 0xe0 == 0x20:
                    value = payload[index] & 0x1f
                    index += 1
                    if value == 0x1f:
                        while index < len(payload):
                            continuation = payload[index]
                            index += 1
                            if not continuation & 0x80:
                                break
                status_200 |= index < len(payload) and payload[index] == 0x88
            elif kind == 9 and stream == 1:
                raise RuntimeError("unexpected CONTINUATION for the fixed response")
            elif kind == 0 and stream == 1:
                body.extend(payload)
                if flags & 1:
                    break
            elif kind == 3 and stream == 1:
                raise RuntimeError(f"server reset positive HTTP/2 request: {payload.hex()}")
        if not status_200 or bytes(body) != BODY:
            raise RuntimeError(f"positive HTTP/2 response mismatch: status={status_200}, body={bytes(body)!r}")


def is_identity_rejection(error):
    if isinstance(error, ssl.SSLCertVerificationError):
        return False
    if isinstance(error, (EOFError, ConnectionResetError)):
        return True
    text = str(error).lower()
    return isinstance(error, ssl.SSLError) and any(
        marker in text for marker in ("alert", "certificate required", "bad certificate", "unknown ca"))


def negative_request(port, version, ca, identity):
    rejected = False
    try:
        try:
            tls = connect(port, version, ca, identity)
        except (ssl.SSLError, EOFError, ConnectionResetError) as error:
            if not is_identity_rejection(error):
                raise
            return
        with tls:
            if tls.selected_alpn_protocol() != "h2":
                raise RuntimeError("negative peer did not negotiate ALPN h2 before identity rejection")
            tls.sendall(request_bytes(port))
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                tls.settimeout(max(0.1, deadline - time.monotonic()))
                try:
                    kind, flags, stream, payload = recv_frame(tls)
                except (EOFError, ssl.SSLError, ConnectionResetError) as error:
                    if not is_identity_rejection(error):
                        raise
                    rejected = True
                    break
                if kind in (1, 0) and stream == 1:
                    raise RuntimeError("invalid client identity received an HTTP/2 response")
                if kind == 3 and stream == 1:
                    rejected = True
                    break
    except (ssl.SSLError, EOFError, ConnectionResetError) as error:
        if not is_identity_rejection(error):
            raise
        rejected = True
    if not rejected:
        raise RuntimeError("invalid or required-missing client identity was not rejected")


def stop_server(process):
    if process.poll() is None:
        try:
            process.stdin.write("stop\n")
            process.stdin.flush()
            process.wait(timeout=5)
        except (BrokenPipeError, subprocess.TimeoutExpired):
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    output = process.stdout.read()
    process.stdin.close()
    process.stdout.close()
    if process.returncode:
        raise RuntimeError(f"provider server exited {process.returncode}: {output}")
    return output


def one_case(binary, provider, version, mode, identity, ca, server_cert, server_key,
             evidence_dir, rows, accept_expected):
    command = [str(binary), provider, str(server_cert), str(server_key), version, mode, str(ca)]
    peer_name = identity[0].stem if identity else "missing"
    case_id = f"{provider}-tls{version.replace('.', '')}-{mode}-{peer_name}"
    process = subprocess.Popen(command, cwd=ROOT, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, bufsize=1)
    outcome, detail = "FAIL", ""
    server_output = []
    try:
        port = wait_ready(process, server_output)
        if accept_expected:
            positive_request(port, version, ca, identity)
            result = "accept"
        else:
            negative_request(port, version, ca, identity)
            result = "reject"
        outcome = "PASS"
        detail = result
        print(f"PASS {case_id}: {result}")
    except Exception as error:
        detail = f"{type(error).__name__}: {error}"
        raise
    finally:
        try:
            server_output.append(stop_server(process))
        finally:
            (evidence_dir / f"{case_id}.server.log").write_text("".join(server_output))
            (evidence_dir / f"{case_id}.peer.log").write_text(detail + "\n")
            rows.append((case_id, provider, version, mode, peer_name, outcome, detail))
            with (evidence_dir / "rows.tsv").open("a") as table:
                row = rows[-1]
                table.write("\t".join(value.replace("\t", " ").replace("\n", " ") for value in row) + "\n")


def main():
    if len(sys.argv) != 1:
        raise SystemExit("usage: python3 tools/server/validate/provider_mtls.py")
    binary = compile_probe()
    target = os.environ.get("TARGET")
    if not target:
        cpu = run([os.environ.get("FPC", "fpc"), "-iTP"], text=True).stdout.strip()
        os_name = run([os.environ.get("FPC", "fpc"), "-iTO"], text=True).stdout.strip()
        target = f"{cpu}-{os_name}"
    profile = os.environ.get("PROFILE", "debug" if os.environ.get("DEBUG") else "default")
    validation_dir = ROOT / "bin" / target / profile / "validation"
    validation_dir.mkdir(parents=True, exist_ok=True)
    evidence_dir = Path(tempfile.mkdtemp(prefix=f"provider-mtls-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-",
                                         dir=validation_dir))
    print(f"provider mTLS evidence: {evidence_dir}", flush=True)
    rows = []
    (evidence_dir / "compile.log").write_text("compiled probe: " + str(binary) + "\n")
    (evidence_dir / "rows.tsv").write_text("case\tprovider\ttls\tauth\tpeer\toutcome\tdetail\n")
    with tempfile.TemporaryDirectory(prefix="provider-mtls-") as temp_name:
        fixture_dir = Path(temp_name) / "certs"
        run(["bash", "tools/client/validate/make-mtls-certs.sh", str(fixture_dir)], timeout=180)
        ca = fixture_dir / "ca.crt"
        server_cert, server_key = fixture_dir / "server.crt", fixture_dir / "server.key"
        valid = (fixture_dir / "client-chain.pem", fixture_dir / "client.key")
        expired = (fixture_dir / "expired.crt", fixture_dir / "expired.key")
        other = (fixture_dir / "other-client.crt", fixture_dir / "other-client.key")
        for provider in ("openssl", "tlslib"):
            for version in ("1.2", "1.3"):
                for identity in (valid, None, expired, other):
                    one_case(binary, provider, version, "require", identity,
                             ca, server_cert, server_key, evidence_dir, rows,
                             identity == valid)
                for identity in (None, valid, expired, other):
                    one_case(binary, provider, version, "request", identity,
                             ca, server_cert, server_key, evidence_dir, rows,
                             identity is None or identity == valid)
    print(f"PASS independent provider client identity matrix: {len(rows)}/32; evidence {evidence_dir}")


if __name__ == "__main__":
    main()
