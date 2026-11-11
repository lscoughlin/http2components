"""Run controlled server performance workloads.

Usage: performance.py seam|tls|ws-sse
TEST_REPO selects a checkout. PERFORMANCE_RUN_ROOT selects the run directory.
"""

import contextlib
import datetime
import json
import os
import pathlib
import re
import signal
import subprocess
import sys
import tempfile
import time

REPO = pathlib.Path(os.environ.get('TEST_REPO', pathlib.Path(__file__).resolve().parents[3])).resolve()
RUN_ROOT = pathlib.Path(os.environ.get('PERFORMANCE_RUN_ROOT', REPO / 'bin/validation/performance')).resolve()
LOG_ROOT = RUN_ROOT / 'logs'
LOG_ROOT.mkdir(parents=True, exist_ok=True)
RUN_MODE = sys.argv[1] if len(sys.argv) > 1 else 'unknown'
OUT = pathlib.Path(tempfile.mkdtemp(prefix=f'performance-{REPO.name}-{RUN_MODE}-', dir=LOG_ROOT))
print(json.dumps(dict(performance_output=str(OUT))), flush=True)
sys.path.insert(0, str(REPO / 'tools/server/validate'))
import provider_live
records = []


def target_profile():
    target = os.environ.get('TARGET')
    if not target:
        fpc = os.environ.get('FPC', 'fpc')
        cpu = subprocess.run([fpc, '-iTP'], cwd=REPO, check=True,
                             capture_output=True, text=True).stdout.strip()
        system = subprocess.run([fpc, '-iTO'], cwd=REPO, check=True,
                                capture_output=True, text=True).stdout.strip()
        target = f'{cpu}-{system}'
    profile = os.environ.get('PROFILE', 'debug' if os.environ.get('DEBUG') else 'default')
    return target, profile


def example_binary(name):
    target, profile = target_profile()
    return REPO / 'bin' / target / profile / 'examples-server' / 'programs' / name


def integration_binary(name):
    target, profile = target_profile()
    return REPO / 'bin' / target / profile / 'integration-test' / 'programs' / name

def stats(pid):
    rss, cpu = provider_live.process_stats(pid)
    links = []
    for f in pathlib.Path(f'/proc/{pid}/fd').iterdir():
        try: links.append(os.readlink(f))
        except FileNotFoundError: pass
    return dict(rss_kib=rss, cpu_seconds=cpu, fd_count=len(links),
                socket_fd_count=sum(x.startswith('socket:') for x in links))

def stop_group(p, grace=3):
    try: os.killpg(p.pid, signal.SIGTERM)
    except ProcessLookupError: pass
    try: p.wait(grace)
    except subprocess.TimeoutExpired: pass
    # The parent may exit on SIGTERM while a descendant ignores it.
    try:
        os.killpg(p.pid, 0)
        os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError: pass
    if p.poll() is None: p.wait()

def command(name, args, timeout=1200, monitor=None, env=None):
    start = datetime.datetime.now(datetime.timezone.utc).isoformat()
    t = time.monotonic(); samples = []
    with (OUT / (name + '.log')).open('w') as f:
        f.write(json.dumps(dict(command=args, start_utc=start, env=env or {})) + '\n'); f.flush()
        child_env = os.environ.copy()
        if env: child_env.update(env)
        p = subprocess.Popen(args, cwd=REPO, stdout=f, stderr=subprocess.STDOUT,
                             env=child_env,
                             start_new_session=True)
        error = None
        try:
            while p.poll() is None:
                if monitor: samples.append(dict(seconds=round(time.monotonic()-t, 3), **stats(monitor)))
                if time.monotonic()-t > timeout:
                    error = TimeoutError(f'{name} timed out after {timeout}s')
                    break
                time.sleep(.5)
        except BaseException as exc:
            error = exc
        finally:
            if error is not None or p.returncode not in (None, 0): stop_group(p)
        if error is not None and p.poll() is None: stop_group(p)
    rec = dict(name=name, command=args, start_utc=start,
               end_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
               elapsed=round(time.monotonic()-t, 3), exit=p.returncode,
               timed_out=isinstance(error, TimeoutError), samples=samples)
    records.append(rec)
    (OUT / 'results.json').write_text(json.dumps(records, indent=2))
    print(json.dumps({k:v for k,v in rec.items() if k!='samples'}), flush=True)
    if error is not None: raise error
    if p.returncode: raise RuntimeError(name + ' failed')
    return (OUT / (name + '.log')).read_text()

class ServerOutput:
    """Read server control lines from a file while stdout writes to that file."""

    def __init__(self, process, path):
        self.process = process
        self.reader = pathlib.Path(path).open('rb')
        self.buffer = bytearray()
        self.pid = process.pid
        self.stdin = process.stdin

    def poll(self):
        return self.process.poll()

    @property
    def returncode(self):
        return self.process.returncode

    def wait(self, timeout=None):
        return self.process.wait(timeout=timeout)

    def read_line(self, timeout, label):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            newline = self.buffer.find(b'\n')
            if newline >= 0:
                raw = bytes(self.buffer[:newline + 1])
                del self.buffer[:newline + 1]
                return raw.decode(errors='replace')
            chunk = self.reader.read(65536)
            if chunk:
                self.buffer.extend(chunk)
                continue
            if self.poll() is not None:
                return None
            time.sleep(0.02)
        raise TimeoutError(f'{label} timed out')

    def wait_for(self, pattern, timeout, label):
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f'{label} timed out')
            line = self.read_line(remaining, label)
            if line is None:
                raise RuntimeError(f'{label}: server exited {self.returncode}')
            match = pattern.fullmatch(line)
            if match:
                return match

    def close(self):
        self.reader.close()


@contextlib.contextmanager
def server(name, args, stop_timeout=10):
    start_utc = datetime.datetime.now(datetime.timezone.utc).isoformat()
    started = time.monotonic()
    log_path = OUT / (name + '-server.log')
    f = log_path.open('wb')
    p = subprocess.Popen(args, cwd=REPO, stdin=subprocess.PIPE, stdout=f,
                         stderr=subprocess.STDOUT, text=True, bufsize=1,
                         start_new_session=True)
    output = ServerOutput(p, log_path)
    port = None
    try:
        while time.monotonic()-started < 10:
            try:
                line = output.read_line(.2, name + ' readiness')
            except TimeoutError:
                continue
            if line is None: break
            m = re.search(r'(?:port |127\.0\.0\.1:)(\d+)', line)
            if m: port = int(m.group(1)); break
        if port is None:
            raise RuntimeError(f'{name} did not become ready; see {log_path}')
        print(json.dumps(dict(server=name, pid=p.pid, port=port, before=stats(p.pid),
                              log=str(log_path))), flush=True)
        yield output, port
    finally:
        active_exception = sys.exc_info()[0] is not None
        cleanup_error = None
        if p.poll() is None:
            try:
                p.stdin.write('stop\n'); p.stdin.flush()
            except (BrokenPipeError, OSError, ValueError) as exc:
                cleanup_error = f'stop request failed: {exc}'
            finally:
                try: p.stdin.close()
                except (OSError, ValueError): pass
            try: p.wait(stop_timeout)
            except subprocess.TimeoutExpired:
                stop_group(p, grace=min(3, stop_timeout))
                cleanup_error = cleanup_error or 'graceful stop timed out'
        if p.returncode not in (None, 0):
            stop_group(p)
        tail_error = None
        try:
            f.flush()
        except OSError as exc:
            tail_error = str(exc)
        finally:
            try: output.close()
            finally: f.close()
        result = dict(server=name, stopped=True, exit=p.returncode,
                      cleanup_error=cleanup_error, tail_error=tail_error,
                      log=str(log_path), log_bytes=log_path.stat().st_size,
                      start_utc=start_utc,
                      end_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      elapsed=round(time.monotonic() - started, 3),
                      pid=p.pid, port=port, timed_out=cleanup_error is not None)
        records.append(dict(kind='server', name=name, **result))
        (OUT / 'results.json').write_text(json.dumps(records, indent=2))
        print(json.dumps(result), flush=True)
        if not active_exception and (cleanup_error or tail_error or p.returncode):
            raise RuntimeError(f'{name} failed cleanup: {cleanup_error or tail_error or p.returncode}; see {log_path}')


def accepted_count(server_output):
    server_output.stdin.write('stats\n')
    server_output.stdin.flush()
    match = server_output.wait_for(re.compile(r'STATS accepted (\d+)\s*'),
                                   3, 'server stats response')
    return int(match.group(1))

def seam():
    for name, mode in [('idle100',['idle','100','20']), ('idle1000',['idle','1000','20']),
                       ('idle10000',['idle','10000','20']), ('active500',['active','500','1']),
                       ('delayed8',['delayed','8','600'])]:
        with server(name,[str(example_binary('interop_server')),'0']) as (p,port):
            before=stats(p.pid)
            args=[sys.executable,'tools/server/seam/seam.py','127.0.0.1',str(port),*mode]
            if mode[0]!='delayed': args += ['--pid',str(p.pid)]
            command(name,args,monitor=p.pid)
            time.sleep(3)
            print(json.dumps(dict(name=name,before=before,settled=stats(p.pid))),flush=True)
    with server('sequential',[str(example_binary('interop_server')),'0']) as (p,port):
        for name,mode in [('idle',['idle','10000','20']),('active',['active','500','1']),('delayed',['delayed','8','600'])]:
            args=[sys.executable,'tools/server/seam/seam.py','127.0.0.1',str(port),*mode]
            if mode[0]!='delayed':args += ['--pid',str(p.pid)]
            command('sequential-'+name,args,monitor=p.pid)
            time.sleep(3)
            print(json.dumps(dict(name='sequential-'+name,settled=stats(p.pid))),flush=True)

def long_lived():
    with tempfile.TemporaryDirectory(prefix='perf-pki-',dir=RUN_ROOT) as temp:
        command('make-pki',['sh','tools/server/certs/make_mtls_pki.sh',temp],60)
        cert=str(pathlib.Path(temp)/'server.crt'); key=str(pathlib.Path(temp)/'server.key')
        ca=str(pathlib.Path(temp)/'ca.crt')
        command('compile-provider-live',[sys.executable,'tools/build.py','compile:server-probe',
                                         'test/integration/server/tls/Http2.Server.ProviderLive.pas'],180)
        binary=integration_binary('Http2.Server.ProviderLive')
        if not binary.is_file(): raise RuntimeError(f'provider probe missing: {binary}')
        command('provider-live',[sys.executable,'tools/server/validate/provider_live.py',cert,key],300,
                env={'PROVIDER_LIVE_BINARY':str(binary)})
        for provider in ['openssl','tlslib']:
            for version in ['1.2','1.3']:
                name=provider+'-'+version+'-million'
                with server(name,[str(binary),provider,cert,key,version]) as (p,port):
                    provider_live.independent_handshake(port,version,ca)
                    provider_live.http2_get(port,version,ca)
                    time.sleep(2)
                    before=stats(p.pid)
                    accepted_before=accepted_count(p)
                    request_log=OUT/(name+'-requests.tsv')
                    report=command(name,['h2load','-n','1000000','-c','1','-m','1',
                                         '--log-file='+str(request_log),f'https://localhost:{port}/'],1800,p.pid)
                    accepted_after=accepted_count(p)
                    if accepted_after-accepted_before != 1:
                        raise RuntimeError(f'{name} accepted {accepted_after-accepted_before} connections during h2load; expected 1')
                    m=re.search(r'requests:\s+(\d+) total,\s+(\d+) started,\s+(\d+) done,\s+(\d+) succeeded,\s+(\d+) failed,\s+(\d+) errored',report)
                    if not m or m.groups()!=('1000000','1000000','1000000','1000000','0','0'):
                        raise RuntimeError(name+' incomplete request summary')
                    durations=[]
                    with request_log.open() as requests:
                        for line in requests:
                            fields=line.split()
                            if len(fields)<3 or fields[1]!='200':
                                raise RuntimeError(name+' request log has invalid status')
                            durations.append(int(fields[2]))
                    if len(durations)!=1000000:raise RuntimeError(name+' missing request rows')
                    durations.sort()
                    after=stats(p.pid);time.sleep(5)
                    print(json.dumps(dict(name=name,before=before,after=after,settled=stats(p.pid),
                                          accepted_before=accepted_before,accepted_after=accepted_after,
                                          request_latency_ms={str(q):durations[min(len(durations)-1,int(q*len(durations)))]/1000 for q in [.5,.9,.99,1]})),flush=True)

def ws_sse():
    with server('ws-load',[str(example_binary('ws_echo')),'127.0.0.1','0','load']) as (wp,wport):
        with server('sse-load',[str(example_binary('sse_replay')),'127.0.0.1','0']) as (sp,sport):
            command('ws-sse-10000',[sys.executable,'tools/server/validate/ws_sse_load.py','127.0.0.1',str(wport),str(sport),'10000','20','50',str(wp.pid),str(sp.pid)],1200)
            time.sleep(5)
            print(json.dumps(dict(ws_settled=stats(wp.pid),sse_settled=stats(sp.pid))),flush=True)

if __name__=='__main__':
    os.chdir(REPO)
    {'seam':seam,'tls':long_lived,'ws-sse':ws_sse}[sys.argv[1]]()
