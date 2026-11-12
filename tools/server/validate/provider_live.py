#!/usr/bin/env python3
"""Exercise each TLS server provider with independent TLS and HTTP/2 peers.

Usage: provider_live.py CERTIFICATE KEY [PROVIDER...]
PROVIDER is openssl or tlslib. With no provider argument, both run in order.
"""
import os
import re
import select
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SOURCE = "test/integration/server/tls/Http2.Server.ProviderLive.pas"
BODY = b"provider-server-ok\n"


def run(command, *, timeout=30, **kwargs):
    result = subprocess.run(command, check=False, timeout=timeout,
                            capture_output=True, **kwargs)
    if result.returncode:
        stdout = result.stdout.decode(errors="replace") if isinstance(result.stdout, bytes) else result.stdout
        stderr = result.stderr.decode(errors="replace") if isinstance(result.stderr, bytes) else result.stderr
        raise RuntimeError(f"command failed with exit {result.returncode}: {command!r}\n{stdout}{stderr}")
    return result


def provider_binary():
    override = os.environ.get("PROVIDER_LIVE_BINARY")
    if override:
        binary = Path(override).expanduser()
        if not binary.is_absolute():
            binary = ROOT / binary
        if not binary.is_file():
            raise RuntimeError(f"PROVIDER_LIVE_BINARY does not exist: {binary}")
        return binary
    target = os.environ.get("TARGET")
    if not target:
        cpu = run([os.environ.get("FPC", "fpc"), "-iTP"], text=True).stdout.strip()
        os_name = run([os.environ.get("FPC", "fpc"), "-iTO"], text=True).stdout.strip()
        target = f"{cpu}-{os_name}"
    profile = os.environ.get("PROFILE", "debug" if os.environ.get("DEBUG") else "default")
    binary = ROOT / "bin" / target / profile / "integration-test" / "programs" / Path(SOURCE).stem
    return binary


def compile_probe():
    if os.environ.get("PROVIDER_LIVE_BINARY"):
        return provider_binary()
    run(["task", "compile:server:probe", "--", SOURCE],
        cwd=ROOT, timeout=180)
    binary = provider_binary()
    if not binary.is_file():
        raise RuntimeError(f"probe compiler did not produce {binary}")
    return binary


def wait_ready(process):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if not select.select([process.stdout], [], [], deadline - time.monotonic())[0]:
            break
        line = process.stdout.readline()
        if not line:
            if process.poll() is not None:
                raise RuntimeError(f"provider server exited {process.returncode}")
            continue
        match = re.fullmatch(r"READY port (\d+)\s*", line)
        if match:
            return int(match.group(1))
        print(line, end="")
    raise TimeoutError("provider server did not report a port in 10 seconds")


def independent_handshake(port, version, ca_file):
    flag = "-tls1_2" if version == "1.2" else "-tls1_3"
    start = time.monotonic()
    result = run(["openssl", "s_client", "-connect", f"localhost:{port}",
                  flag, "-alpn", "h2", "-verify_return_error", "-verify_hostname",
                  "localhost", "-CAfile", ca_file], input=b"", timeout=10)
    report = (result.stdout + result.stderr).decode(errors="replace")
    expected = "TLSv1.2" if version == "1.2" else "TLSv1.3"
    if expected not in report or "ALPN protocol: h2" not in report:
        raise RuntimeError(f"independent OpenSSL peer did not negotiate {expected}/h2: {report}")
    return time.monotonic() - start


def http2_get(port, version, ca_file):
    args = ["curl", "--silent", "--show-error", "--cacert", ca_file, "--http2",
            "--tlsv" + version, "--tls-max", version, "--max-time", "10",
            "--write-out", "\\n%{http_version} %{http_code} %{time_total} %{size_download}",
            f"https://localhost:{port}/"]
    result = run(args, timeout=15)
    body, stats = result.stdout.rsplit(b"\n", 1)
    fields = stats.decode().split()
    if body != BODY or fields[:2] != ["2", "200"] or fields[3] != str(len(BODY)):
        raise RuntimeError(f"independent curl result mismatch: body={body!r}, stats={stats!r}")
    return float(fields[2])


def churn(port, version, ca_file, count=50):
    flag = "-tls1_2" if version == "1.2" else "-tls1_3"
    start = time.monotonic()
    for _ in range(count):
        run(["openssl", "s_client", "-connect", f"localhost:{port}",
             flag, "-alpn", "h2", "-verify_return_error", "-verify_hostname",
             "localhost", "-CAfile", ca_file], input=b"", timeout=10)
    return time.monotonic() - start


def process_stats(pid):
    raw = run(["ps", "-o", "rss=,time=", "-p", str(pid)], text=True).stdout.split()
    if len(raw) != 2:
        raise RuntimeError(f"server process {pid} is absent")
    from ws_sse_load import cpu_seconds
    return int(raw[0]), cpu_seconds(raw[1])


def check_h2load_report(data):
    report = data.decode(errors="replace")
    summary = re.search(
        r"requests:\s+(\d+) total,\s+(\d+) started,\s+(\d+) done,\s+(\d+) succeeded,\s+(\d+) failed,\s+(\d+) errored",
        report)
    if not summary or summary.groups() != ("200", "200", "200", "200", "0", "0"):
        raise RuntimeError(f"h2load did not complete 200 requests successfully:\n{report}")
    return report


def main():
    if len(sys.argv) not in (3, 4, 5):
        raise SystemExit(__doc__)
    cert, key = map(str, map(Path, sys.argv[1:3]))
    ca_file = str(Path(cert).with_name("ca.crt"))
    if not Path(ca_file).is_file():
        raise SystemExit(f"trusted CA file is absent: {ca_file}")
    providers = sys.argv[3:] or ["openssl", "tlslib"]
    if any(provider not in ("openssl", "tlslib") for provider in providers):
        raise SystemExit("provider must be openssl or tlslib")
    binary = compile_probe()
    completed = 0
    started = time.monotonic()
    for provider in providers:
        for version in ("1.2", "1.3"):
            process = subprocess.Popen([str(binary), provider, cert, key, version],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True, bufsize=1)
            try:
                port = wait_ready(process)
                base_rss, base_cpu = process_stats(process.pid)
                independent = independent_handshake(port, version, ca_file)
                elapsed = http2_get(port, version, ca_file)
                churn_elapsed = churn(port, version, ca_file)
                h2 = run(["h2load", "-n", "200", "-c", "10", "-m", "6",
                          f"https://localhost:{port}/"], timeout=60)
                h2_report = check_h2load_report(h2.stdout + h2.stderr)
                measured_rss, measured_cpu = process_stats(process.pid)
                time.sleep(1)
                settled_rss, settled_cpu = process_stats(process.pid)
                print(f"PASS independent TLS {version}/h2: {provider}; fixed HTTP/2 response; "
                      f"verified OpenSSL handshake {independent * 1000:.2f} ms; "
                      f"curl request {elapsed * 1000:.2f} ms; verified OpenSSL churn 50 in {churn_elapsed:.2f} s")
                print(f"PERF {provider} TLS {version}: h2load 200 requests; "
                      f"server RSS {base_rss} -> {measured_rss} KiB; after disconnects {settled_rss} KiB; "
                      f"CPU {base_cpu:.2f} -> {measured_cpu:.2f} s (settled {settled_cpu:.2f} s)")
                print(h2_report.strip())
                completed += 1
            finally:
                if process.poll() is None:
                    try:
                        process.stdin.write("stop\n")
                        process.stdin.flush()
                        process.wait(timeout=5)
                    except Exception:
                        process.terminate()
                        try:
                            process.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
                process.stdin.close()
                process.stdout.close()
                if process.returncode != 0:
                    raise RuntimeError(f"{provider} TLS {version} server exited {process.returncode}")
                print(f"cleanup {provider} TLS {version}: server stopped (exit {process.returncode})")
    expected = 2 * len(providers)
    print(f"PASS provider live checks: {completed}/{expected}; runtime {time.monotonic() - started:.1f} s")


if __name__ == "__main__":
    main()
