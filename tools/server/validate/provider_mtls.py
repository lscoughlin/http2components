#!/usr/bin/env python3
"""Check independent client identity handling for both TLS providers."""
import os
import re
import select
import socket
import ssl
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import h2.config
import h2.connection
import h2.events

ROOT = Path(__file__).resolve().parents[3]
SOURCE = "test/integration/server/tls/Http2.Server.ProviderLive.pas"
BODY = b"provider-server-ok\n"


def run(command, *, timeout=30, **kwargs):
    result = subprocess.run(command, cwd=ROOT, check=False, timeout=timeout,
                            capture_output=True, **kwargs)
    if result.returncode:
        stdout = result.stdout.decode(errors="replace") if isinstance(result.stdout, bytes) else result.stdout
        stderr = result.stderr.decode(errors="replace") if isinstance(result.stderr, bytes) else result.stderr
        raise RuntimeError(f"command failed with exit {result.returncode}: {command!r}\n{stdout}{stderr}")
    return result


def compile_probe():
    supplied = os.environ.get("PROVIDER_LIVE_BINARY")
    if supplied:
        binary = Path(supplied).resolve()
        if not binary.is_file():
            raise RuntimeError(f"provider probe binary does not exist: {binary}")
        return binary, f"Using supplied provider probe binary: {binary}\nCompilation skipped.\n"
    result = run([sys.executable, "tools/build.py", "compile:server:probe", SOURCE], timeout=180)
    target = os.environ.get("TARGET")
    if not target:
        cpu = run([os.environ.get("FPC", "fpc"), "-iTP"], text=True).stdout.strip()
        os_name = run([os.environ.get("FPC", "fpc"), "-iTO"], text=True).stdout.strip()
        target = f"{cpu}-{os_name}"
    profile = os.environ.get("PROFILE", "debug" if os.environ.get("DEBUG") else "default")
    binary = ROOT / "bin" / target / profile / "integration-test" / "programs" / Path(SOURCE).stem
    if not binary.is_file():
        raise RuntimeError(f"probe compiler did not produce {binary}")
    output = result.stdout.decode(errors="replace") if isinstance(result.stdout, bytes) else result.stdout
    error = result.stderr.decode(errors="replace") if isinstance(result.stderr, bytes) else result.stderr
    return binary, output + error


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


def check_negotiated_tls(tls, version, alpn_required=True):
    expected = "TLSv1.2" if version == "1.2" else "TLSv1.3"
    actual = tls.version()
    alpn = tls.selected_alpn_protocol()
    if actual != expected:
        raise RuntimeError(f"negotiated TLS={actual!r} ALPN={alpn!r}, expected TLS={expected}")
    if alpn_required and alpn != "h2":
        raise RuntimeError(f"negotiated TLS={actual!r} ALPN={alpn!r}, expected ALPN='h2'")
    return actual, alpn


def positive_request(port, version, ca, identity):
    with connect(port, version, ca, identity) as tls:
        actual_version, alpn = check_negotiated_tls(tls, version)
        connection = h2.connection.H2Connection(
            config=h2.config.H2Configuration(client_side=True, header_encoding="utf-8"))
        connection.initiate_connection()
        stream_id = connection.get_next_available_stream_id()
        connection.send_headers(stream_id, [
            (":method", "GET"), (":scheme", "https"), (":authority", f"localhost:{port}"),
            (":path", "/")], end_stream=True)
        tls.sendall(connection.data_to_send())
        body = bytearray()
        status = None
        stream_ended = False
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline and not stream_ended:
            tls.settimeout(max(0.1, deadline - time.monotonic()))
            data = tls.recv(65535)
            if not data:
                raise EOFError("TLS peer closed before HTTP/2 stream ended")
            for event in connection.receive_data(data):
                if isinstance(event, h2.events.ResponseReceived) and event.stream_id == stream_id:
                    status = dict(event.headers).get(":status")
                elif isinstance(event, h2.events.DataReceived) and event.stream_id == stream_id:
                    body.extend(event.data)
                    connection.acknowledge_received_data(event.flow_controlled_length, stream_id)
                elif isinstance(event, h2.events.StreamEnded) and event.stream_id == stream_id:
                    stream_ended = True
                elif isinstance(event, h2.events.StreamReset) and event.stream_id == stream_id:
                    raise RuntimeError(f"server reset positive HTTP/2 request: {event.error_code}")
                elif isinstance(event, h2.events.ConnectionTerminated):
                    raise RuntimeError(f"server terminated positive HTTP/2 connection: {event.error_code}")
            pending = connection.data_to_send()
            if pending:
                tls.sendall(pending)
        if not stream_ended or status != "200" or bytes(body) != BODY:
            raise RuntimeError(f"TLS={actual_version} ALPN={alpn} HTTP/2 response mismatch: "
                               f"ended={stream_ended}, status={status!r}, body={bytes(body)!r}")
        return f"TLS={actual_version} ALPN={alpn} HTTP/2 status={status} END_STREAM=yes body={bytes(body)!r}"


def is_identity_rejection(error):
    if isinstance(error, ssl.SSLCertVerificationError):
        return False
    if isinstance(error, (EOFError, ConnectionResetError)):
        return True
    text = str(error).lower()
    return isinstance(error, ssl.SSLError) and any(
        marker in text for marker in ("alert", "unexpected eof", "eof occurred"))


def negative_request(port, version, ca, identity):
    try:
        tls = connect(port, version, ca, identity)
    except (ssl.SSLError, EOFError, ConnectionResetError) as error:
        if not is_identity_rejection(error):
            raise
        return f"TLS negotiation rejected identity: {type(error).__name__}: {error}"
    with tls:
        actual_version, alpn = check_negotiated_tls(tls, version)
        try:
            application_data = tls.recv(1)
        except (ssl.SSLError, EOFError, ConnectionResetError) as error:
            if not is_identity_rejection(error):
                raise
            return f"TLS={actual_version} ALPN={alpn} identity rejection: {type(error).__name__}: {error}"
        if application_data:
            raise RuntimeError(f"TLS={actual_version} ALPN={alpn}: authentication completed and "
                               "the peer sent HTTP/2 application data")
        return f"TLS={actual_version} ALPN={alpn} identity rejection: EOF"


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
    process = None
    outcome, detail = "FAIL", ""
    server_output = []
    try:
        process = subprocess.Popen(command, cwd=ROOT, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, bufsize=1)
        port = wait_ready(process, server_output)
        if accept_expected:
            detail = positive_request(port, version, ca, identity)
        else:
            detail = negative_request(port, version, ca, identity)
        outcome = "PASS"
    except Exception as error:
        detail = f"{type(error).__name__}: {error}"
    if process is not None:
        try:
            server_output.append(stop_server(process))
        except Exception as error:
            outcome = "FAIL"
            detail = f"{detail}; cleanup failed: {type(error).__name__}: {error}"
            server_output.append(f"cleanup failed: {error}\n")
    (evidence_dir / f"{case_id}.server.log").write_text("".join(server_output))
    (evidence_dir / f"{case_id}.peer.log").write_text(detail + "\n")
    rows.append((case_id, provider, version, mode, peer_name, outcome, detail))
    with (evidence_dir / "rows.tsv").open("a") as table:
        row = rows[-1]
        table.write("\t".join(value.replace("\t", " ").replace("\n", " ") for value in row) + "\n")
    print(f"{outcome} {case_id}: {detail}", flush=True)
    return outcome == "PASS"


def main():
    if len(sys.argv) != 1:
        raise SystemExit("usage: python3 tools/server/validate/provider_mtls.py")
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
    (evidence_dir / "rows.tsv").write_text("case\tprovider\ttls\tauth\tpeer\toutcome\tdetail\n")
    try:
        binary, compiler_output = compile_probe()
    except Exception as error:
        (evidence_dir / "compile.log").write_text(f"compiler failed: {error}\n")
        raise
    (evidence_dir / "compile.log").write_text(compiler_output)
    with tempfile.TemporaryDirectory(prefix="provider-mtls-") as temp_name:
        fixture_dir = Path(temp_name) / "certs"
        run(["bash", "tools/client/validate/make-mtls-certs.sh", str(fixture_dir)], timeout=180)
        ca = fixture_dir / "ca.crt"
        server_cert, server_key = fixture_dir / "server.crt", fixture_dir / "server.key"
        valid = (fixture_dir / "client-chain.pem", fixture_dir / "client.key")
        expired = (fixture_dir / "expired.crt", fixture_dir / "expired.key")
        other = (fixture_dir / "other-client.crt", fixture_dir / "other-client.key")
        all_ok = True
        for provider in ("openssl", "tlslib"):
            for version in ("1.2", "1.3"):
                for identity in (valid, None, expired, other):
                    case_ok = one_case(binary, provider, version, "require", identity,
                                       ca, server_cert, server_key, evidence_dir, rows,
                                       identity == valid)
                    all_ok = case_ok and all_ok
                for identity in (None, valid, expired, other):
                    case_ok = one_case(binary, provider, version, "request", identity,
                                       ca, server_cert, server_key, evidence_dir, rows,
                                       identity is None or identity == valid)
                    all_ok = case_ok and all_ok
    print(f"provider client identity matrix: {len(rows)}/32 passed={sum(row[5] == 'PASS' for row in rows)}; evidence {evidence_dir}")
    if len(rows) != 32 or not all_ok:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
