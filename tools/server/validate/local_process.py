#!/usr/bin/env python3
"""Bounded HTTP/2 exchange between separate local client and server programs."""
import os
import platform
import re
import selectors
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
MORMOT_PARTS = ('core', 'lib', 'net', 'crypt')


def compiler():
    return os.environ.get('FPC', 'fpc')


def fpc_info(option):
    return subprocess.check_output([compiler(), option], text=True).strip()


def safe_name(value, label):
    if not re.fullmatch(r'[A-Za-z0-9._-]+', value) or value in ('.', '..'):
        raise SystemExit(f'{label} must contain only letters, numbers, dot, underscore, or dash')
    return value


def target_name():
    default = f"{fpc_info('-iTP')}-{fpc_info('-iTO')}"
    return safe_name(os.environ.get('TARGET', default), 'TARGET')


def profile():
    default = 'debug' if os.environ.get('DEBUG') else 'default'
    return safe_name(os.environ.get('PROFILE', default), 'PROFILE')


def output_dirs(component):
    base = ROOT / 'bin' / target_name() / profile() / component
    units, programs = base / 'units', base / 'programs'
    units.mkdir(parents=True, exist_ok=True)
    programs.mkdir(parents=True, exist_ok=True)
    return units, programs


def mormot_root():
    override = (os.environ.get('MORMOT2_ROOT') or os.environ.get('MORMOT_ROOT')
                or os.environ.get('MORMOT'))
    path = Path(override) if override else ROOT / 'third_party' / 'mORMot2'
    if not path.is_absolute():
        path = ROOT / path
    if path.name == 'src':
        path = path.parent
    path = path.resolve()
    if not (path / 'src').is_dir():
        raise SystemExit(f'Pinned mORMot2 is missing: {path}; run the dependency setup task')
    return path


def open_ssl_env():
    env = dict(os.environ)
    if 'OPENSSL_LIBPATH' not in env and platform.system() == 'Darwin':
        prefix = ('/opt/homebrew' if platform.machine().lower() in ('arm64', 'aarch64')
                  else '/usr/local')
        env['OPENSSL_LIBPATH'] = f'{prefix}/opt/openssl@3/lib'
    elif 'OPENSSL_LIBPATH' not in env and platform.system() == 'Linux':
        triplet = {'x86_64': 'x86_64-linux-gnu',
                   'aarch64': 'aarch64-linux-gnu'}.get(platform.machine().lower())
        if triplet:
            env['OPENSSL_LIBPATH'] = f'/usr/lib/{triplet}'
    return env


def user_flags():
    return shlex.split(os.environ.get('FPCFLAGS', ''))


def mormot_flags():
    src = mormot_root() / 'src'
    return [f'-Fu{src / part}' for part in MORMOT_PARTS], f"-Fl{src.parent / 'static' / target_name()}"


def run(args, env=None, timeout=None):
    command = shlex.join(args)
    if len(command) > 1200:
        command = command[:900] + f' ... [{len(args)} arguments, {len(command)} characters]'
    print('+ ' + command, flush=True)
    process = subprocess.Popen(args, cwd=ROOT, env=env, start_new_session=timeout is not None)
    try:
        result = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise SystemExit(f'Command exceeded its {timeout}s deadline; process group stopped')
    if result:
        raise SystemExit(result)


def provider_flags():
    """Return the compiler flags for the OpenSSL provider units."""
    parts, static = mormot_flags()
    units, _ = output_dirs('openssl')
    return ['-O2', '-vw', '-Mdelphi', '-Fucommon/src', '-Futls/openssl/src',
            '-dUSE_OPENSSL', *parts, static, f'-Fu{units}']


def build_openssl(env):
    """Compile the OpenSSL provider package facade."""
    units, programs = output_dirs('openssl')
    parts, static = mormot_flags()
    flags = ['-O2', '-vw', '-Mdelphi', '-dUSE_OPENSSL', '-Fucommon/src',
             '-Futls/openssl/src', *parts, static, *user_flags()]
    run([compiler(), *flags, f'-FU{units}', f'-FE{programs}',
         'tls/openssl/src/Http2.OpenSSL.pas'], env=env, timeout=300)


def compile_example_server(env):
    units, programs = output_dirs('examples-server')
    units = units / 'interop_server'
    shutil.rmtree(units, ignore_errors=True)
    units.mkdir(parents=True, exist_ok=True)
    parts, static = mormot_flags()
    flags = ['-O2', '-vw', '-Mdelphi', '-Fucommon/src', '-Fuclient/src', '-Fuserver/src',
             *parts, static, f"-Fu{output_dirs('common')[0]}",
             '-Fu./examples', '-Fu./examples/client', '-Fu./examples/server',
             '-Fu./examples/integration', *user_flags(), *provider_flags()]
    run([compiler(), *flags, f'-FU{units}', f'-FE{programs}',
         'examples/server/interop_server.pas'], env=env)
    return programs / 'interop_server'


def compile_probe_client(env):
    units, programs = output_dirs('client-test')
    parts, static = mormot_flags()
    fcl = fpc_unit_root() + '/fcl-fpcunit'
    flags = ['-O2', '-vw', '-Mdelphi', '-Fucommon/src', '-Fuclient/src', *parts, static,
             f"-Fu{output_dirs('common')[0]}", f'-Fu{fcl}',
             '-Fu./test', '-Fu./test/common', '-Fu./test/client', '-Fu./test/server',
             '-Fu./test/api', '-Fu./test/integration', '-Fu./test/support/tls',
             '-Fu./examples', '-Fu./examples/client', '-Fu./examples/server',
             '-Fu./test/integration/server/tls', '-Fu./test/integration/server/mtls',
             '-dUSE_OPENSSL', '-Futls/openssl/src', *parts,
             f"-Fu{output_dirs('openssl')[0]}", *user_flags()]
    run([compiler(), *flags, f'-FU{units}', f'-FE{programs}', 'tools/client/h2probe.pas'],
        env=env)
    return programs / 'h2probe'


def fpc_unit_root():
    override = os.environ.get('FPC_UNITS')
    if override:
        return override
    version = fpc_info('-iV')
    base = '/usr/local/lib/fpc' if platform.system() == 'Darwin' else '/usr/lib/fpc'
    return f'{base}/{version}/units/{target_name()}'


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
    env = open_ssl_env()
    build_openssl(env)
    server = compile_example_server(env)
    client = compile_probe_client(env)
    openssl_bin = Path(env.get('OPENSSL_LIBPATH', '')).parent / 'bin'
    if (openssl_bin / 'openssl').is_file():
        env['PATH'] = str(openssl_bin) + os.pathsep + env.get('PATH', '')
    exchange(server, client, env)
    generated = ROOT / 'bin' / target_name() / profile() / 'integration-test'
    generated.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='process-pki-', dir=generated) as pki:
        run(['sh', 'tools/server/certs/make_mtls_pki.sh', pki], env=env, timeout=30)
        exchange(server, client, env, pki)


if __name__ == '__main__':
    main()
