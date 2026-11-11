#!/usr/bin/env python3
"""Bounded HTTP/2 exchange between separate local client and server programs."""
import os
import re
import selectors
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tools import build


def exchange(server, client, env, pki=None):
    args = [str(server), '0']
    if pki:
        args += [f'--cert={pki}/server.crt', f'--key={pki}/server.key']
    process = subprocess.Popen(args, cwd=ROOT, env=env, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            if not selector.select(5):
                raise RuntimeError('Server readiness exceeded five seconds')
            ready = process.stdout.readline().decode()
        match = re.search(r'listens on port (\d+)', ready)
        if not match:
            raise RuntimeError(f'Server did not report a port: {ready}')
        scheme = 'https' if pki else 'http'
        options = ['--insecure'] if pki else ['--clear-text=prior-knowledge']
        result = subprocess.run([str(client), f'--url={scheme}://localhost:{match[1]}/',
                                 *options], cwd=ROOT, env=env, capture_output=True,
                                text=True, timeout=10)
        print(result.stdout, end='')
        if result.returncode or 'RESULT=success status=200' not in result.stdout:
            raise RuntimeError(f'Client exchange failed: {result.stderr}')
        process.stdin.close()
        process.stdin = None
        output, _ = process.communicate(timeout=5)
        if process.returncode or b'the validation server stopped' not in output:
            raise RuntimeError('Server did not stop cleanly')
        print(f'PASS separate processes: {scheme}')
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def main():
    server = build.compile_file(ROOT / 'examples/server/interop_server.pas', 'examples-server')
    client = build.compile_file(ROOT / 'tools/client/h2probe.pas', 'client-test', tests=True)
    env = build.open_ssl_env()
    openssl_bin = Path(env.get('OPENSSL_LIBPATH', '')).parent / 'bin'
    if (openssl_bin / 'openssl').is_file():
        env['PATH'] = str(openssl_bin) + os.pathsep + env.get('PATH', '')
    exchange(server, client, env)
    generated = ROOT / 'bin' / build.target_name() / build.profile() / 'integration-test'
    generated.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='process-pki-', dir=generated) as pki:
        build.run(['sh', 'tools/server/certs/make_mtls_pki.sh', pki], env=env, timeout=30)
        exchange(server, client, env, pki)


if __name__ == '__main__':
    main()
