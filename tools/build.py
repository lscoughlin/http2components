#!/usr/bin/env python3
"""Shared Make and Task build driver for http2components."""

from __future__ import annotations

import os
import platform
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import fcntl
import json
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.check.repository import strip_pascal  # noqa: E402
from tools.components import COMPONENTS, PACKAGE_COMPONENT  # noqa: E402

HARNESS_REV = "0bc075cc21e5a247dfd222e005d1e7e5679d2bff"
DEPENDENCY_RECORDS = json.loads(
    (ROOT / "tools" / "dependencies.json").read_text())["dependencies"]
MORMOT_REV = DEPENDENCY_RECORDS["mORMot2"]["revision"]
DEPENDENCIES = {name: (record["origin"], record["revision"])
                for name, record in DEPENDENCY_RECORDS.items()}


def run(args: list[str], *, env: dict[str, str] | None = None, cwd: Path = ROOT,
        timeout: int | None = None) -> None:
    command = shlex.join(args)
    if len(command) > 1200:
        print("+ " + command[:900] + f" ... [{len(args)} arguments, {len(command)} characters]", flush=True)
    else:
        print("+ " + command, flush=True)
    proc = subprocess.Popen(args, cwd=cwd, env=env, start_new_session=timeout is not None)
    try:
        result = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
        raise SystemExit(f"Command exceeded its {timeout}s deadline; process group stopped")
    if result:
        raise SystemExit(result)


def required(path: Path, label: str) -> Path:
    if not path.exists():
        raise SystemExit(f"Required {label} is missing: {path.relative_to(ROOT)}")
    return path


def compiler() -> str:
    return os.environ.get("FPC", "fpc")


def target_name() -> str:
    cpu = subprocess.check_output([compiler(), "-iTP"], text=True).strip()
    os_name = subprocess.check_output([compiler(), "-iTO"], text=True).strip()
    target = os.environ.get("TARGET", f"{cpu}-{os_name}")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", target) or target in (".", ".."):
        raise SystemExit("TARGET must contain only letters, numbers, dot, underscore, or dash")
    return target


def profile() -> str:
    value = os.environ.get("PROFILE", "debug" if os.environ.get("DEBUG") else "default")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", value) or value in (".", ".."):
        raise SystemExit("PROFILE must contain only letters, numbers, dot, underscore, or dash")
    return value


def output(component: str) -> tuple[Path, Path]:
    base = ROOT / "bin" / target_name() / profile() / component
    units, programs = base / "units", base / "programs"
    units.mkdir(parents=True, exist_ok=True)
    programs.mkdir(parents=True, exist_ok=True)
    return units, programs


def fpc_unit_root() -> str:
    override = os.environ.get("FPC_UNITS")
    if override:
        return override
    version = subprocess.check_output([compiler(), "-iV"], text=True).strip()
    target = target_name()
    if platform.system() == "Darwin":
        return f"/usr/local/lib/fpc/{version}/units/{target}"
    return f"/usr/lib/fpc/{version}/units/{target}"


def base_flags(component: str, *, tests: bool = False) -> list[str]:
    role = component.removesuffix("-test")
    if role == "tls-client":
        role = "client"
    tls_integration = role == "tls-integration"
    if tls_integration:
        role = "integration"
    if role.startswith("examples-"):
        role = "examples"
    flags = ["-O2", "-vw", "-Mdelphi", f"-Fu{COMPONENTS['common']['source']}"]
    if role in ("openssl", "tlslib"):
        flags.append(f"-Fu{COMPONENTS[role]['source']}")
    if role == "openssl":
        verify_mormot()
        mormot = dependency_root("mORMot2") / "src"
        flags.extend(("-dUSE_OPENSSL", *(f"-Fu{mormot / part}" for part in ("core", "lib", "net", "crypt"))))
    if role == "tlslib":
        for name in ("HashLib4Pascal", "SimpleBaseLib4Pascal", "CryptoLib4Pascal", "TlsLib4Pascal"):
            verify_dependency(name)
        flags.extend(tlslib_flags())
        bootstrap = ROOT / "bin" / target_name() / profile() / "tlslib" / "units" / "bootstrap"
        if bootstrap.exists():
            flags.append(f"-Fu{bootstrap}")
        flags.append(f"-Fu{ROOT / 'bin' / target_name() / profile() / 'tlslib' / 'units'}")
    if role in ("client", "readers", "examples", "api", "integration"):
        flags.append(f"-Fu{COMPONENTS['client']['source']}")
    if role in ("server", "examples", "api", "integration"):
        flags.append(f"-Fu{COMPONENTS['server']['source']}")
    if role in ("client", "server", "readers", "examples", "api", "integration"):
        verify_mormot()
        mormot = dependency_root("mORMot2") / "src"
        for part in ("core", "lib", "net", "crypt"):
            flags.append(f"-Fu{mormot / part}")
        flags.append(f"-Fu{ROOT / 'bin' / target_name() / profile() / 'common' / 'units'}")
    if tls_integration:
        for provider in ("openssl", "tlslib"):
            flags.extend((f"-Fu{COMPONENTS[provider]['source']}",
                          f"-Fu{ROOT / 'bin' / target_name() / profile() / provider / 'units'}"))
        flags.extend(tlslib_flags())
        flags.append(f"-Fu{ROOT / 'bin' / target_name() / profile() / 'tlslib' / 'units' / 'bootstrap'}")
        flags.append("-dUSE_OPENSSL")
    if role == "examples":
        flags.extend(("-Fu./examples", "-Fu./examples/client", "-Fu./examples/server",
                      "-Fu./examples/integration"))
    if tests:
        unit_root = fpc_unit_root()
        flags.append(f"-Fu{Path(unit_root) / 'fcl-fpcunit'}")
        if component == "common-test":
            flags.extend(("-Fu./test/common", "-Fu./test/support/tls"))
        else:
            flags.extend(("-Fu./test", "-Fu./test/common", "-Fu./test/client",
                          "-Fu./test/server", "-Fu./test/api", "-Fu./test/integration",
                          "-Fu./test/support/tls", "-Fu./examples", "-Fu./examples/client",
                          "-Fu./examples/server", "-Fu./test/integration/server/tls",
                          "-Fu./test/integration/server/mtls"))
    flags.extend(shlex.split(os.environ.get("FPCFLAGS", "")))
    return flags


def verify_mormot() -> None:
    verify_dependency("mORMot2")


def dependency_root(name: str) -> Path:
    override = os.environ.get(name.upper() + "_ROOT")
    if name == "mORMot2" and not override:
        override = os.environ.get("MORMOT_ROOT") or os.environ.get("MORMOT")
    path = Path(override) if override else ROOT / "third_party" / name
    if not path.is_absolute():
        path = ROOT / path
    if name == "mORMot2" and path.name == "src":
        path = path.parent
    return path.resolve()


def verify_dependency(name: str) -> Path:
    url, revision = DEPENDENCIES[name]
    repo = dependency_root(name)
    if name == "mORMot2" and repo.name == "src":
        repo = repo.parent
    if not (repo / ".git").exists():
        raise SystemExit(f"Pinned {name} is missing; run make setup-deps (expected {revision})")
    try:
        current = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"],
                                          cwd=ROOT, text=True).strip()
        origin = subprocess.check_output(["git", "-C", str(repo), "remote", "get-url", "origin"],
                                         cwd=ROOT, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        raise SystemExit(f"Cannot verify {name} checkout at {repo}")
    if current != revision:
        raise SystemExit(f"{name} revision is {current}; expected {revision}")
    if origin.rstrip("/") != url.rstrip("/"):
        raise SystemExit(f"{name} origin is {origin}; expected {url}")
    status = subprocess.check_output(["git", "-C", str(repo), "status", "--porcelain",
                                      "--untracked-files=all"], cwd=ROOT, text=True)
    if status.strip():
        raise SystemExit(f"{name} checkout has local changes; restore it to the pinned revision")
    license_record = DEPENDENCY_RECORDS[name]["license_file"]
    license_path = repo / license_record
    if not license_path.is_file():
        raise SystemExit(f"{name} license notice is missing: {license_path}")
    project_notice = DEPENDENCY_RECORDS[name].get("project_notice")
    if project_notice and not (ROOT / project_notice).is_file():
        raise SystemExit(f"{name} project license notice is missing: {ROOT / project_notice}")
    return repo


def compile_file(source: Path, component: str, *, tests: bool = False) -> Path:
    source = required(source, f"{component} source")
    units, programs = output(component)
    args = [compiler(), *base_flags(component, tests=tests),
            f"-FU{units}", f"-FE{programs}", str(source.relative_to(ROOT))]
    uses_tls = component in ("client", "server", "readers", "examples", "api-test", "integration-test", "openssl", "openssl-test", "tls-integration-test") or component.startswith("examples-")
    run(args, env=open_ssl_env() if uses_tls else None)
    return programs / source.stem


def open_ssl_env() -> dict[str, str]:
    env = dict(os.environ)
    if "OPENSSL_LIBPATH" not in env and platform.system() == "Darwin":
        prefix = "/opt/homebrew" if platform.machine().lower() in ("arm64", "aarch64") else "/usr/local"
        env["OPENSSL_LIBPATH"] = f"{prefix}/opt/openssl@3/lib"
    elif "OPENSSL_LIBPATH" not in env and platform.system() == "Linux":
        triplet = {"x86_64": "x86_64-linux-gnu", "aarch64": "aarch64-linux-gnu"}.get(platform.machine().lower())
        if triplet:
            env["OPENSSL_LIBPATH"] = f"/usr/lib/{triplet}"
    return env


def build(component: str) -> None:
    facade = ("client/src/Http2.Client.Readers.pas" if component == "readers" else
              str(Path(COMPONENTS[component]["package_dir"]) /
                  ("http2openssl.pas" if component == "openssl" else "http2tlslib.pas"))
              if component in ("openssl", "tlslib") else COMPONENTS[component]["facade"])
    if component == "common":
        lock_path = ROOT / "bin" / target_name() / profile() / "common" / "build.lock"
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        with lock_path.open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            compile_file(ROOT / facade, component)
    elif component in ("openssl", "tlslib"):
        source = ROOT / facade
        if component == "openssl":
            verify_mormot()
            units, programs = output("openssl")
            mormot = dependency_root("mORMot2") / "src"
            flags = ["-O2", "-vw", "-Mdelphi", "-dUSE_OPENSSL",
                     f"-Fu{COMPONENTS['common']['source']}", f"-Fu{COMPONENTS['openssl']['source']}"]
            flags.extend(f"-Fu{mormot / part}" for part in ("core", "lib", "net", "crypt"))
            flags.extend(shlex.split(os.environ.get("FPCFLAGS", "")))
            run([compiler(), *flags, f"-FU{units}", f"-FE{programs}",
                 str(source.relative_to(ROOT))], env=open_ssl_env(), timeout=300)
        else:
            for name in ("HashLib4Pascal", "SimpleBaseLib4Pascal", "CryptoLib4Pascal", "TlsLib4Pascal"):
                verify_dependency(name)
            # The pinned dependency graph has a compiler cycle unless the FPC
            # package units are seeded in the order declared by TLS-02.
            binary = compile_provider_tlslib(source)
        return
    else:
        compile_file(ROOT / facade, component)


def tlslib_flags() -> list[str]:
    roots = [dependency_root("TlsLib4Pascal") / "TlsLib" / "src",
             dependency_root("CryptoLib4Pascal") / "CryptoLib" / "src",
             dependency_root("HashLib4Pascal") / "HashLib" / "src",
             dependency_root("SimpleBaseLib4Pascal") / "SimpleBaseLib" / "src"]
    directories = {source.parent for base in roots for source in base.rglob("*.pas")}
    includes = {source.parent for base in roots for source in base.rglob("*.inc")}
    preferred = [roots[1] / "Math" / "EC" / "Multiplier", roots[1] / "Math" / "EC"]
    dirs = [path for path in preferred if path.exists()]
    dirs.extend(sorted(directories - set(dirs)))
    includes.update(directories)
    return [f"-Fu{path}" for path in dirs] + [f"-Fi{path}" for path in sorted(includes)]


def compile_provider_tlslib(source: Path) -> Path:
    units, programs = output("tlslib")
    package_units = output("tlslib")[0] / "bootstrap"
    package_units.mkdir(parents=True, exist_ok=True)
    flags = ["-O2", "-vw", "-Mdelphi", *tlslib_flags(),
             *shlex.split(os.environ.get("FPCFLAGS", ""))]
    packages = [dependency_root("HashLib4Pascal") / "HashLib/src/Packages/FPC/HashLib4PascalPackage.pas",
                dependency_root("SimpleBaseLib4Pascal") / "SimpleBaseLib/src/Packages/FPC/SimpleBaseLib4PascalPackage.pas",
                dependency_root("CryptoLib4Pascal") / "CryptoLib/src/Packages/FPC/CryptoLib4PascalPackage.pas"]
    for package in packages:
        if not package.is_file():
            raise SystemExit(f"Pinned TlsLib dependency package is missing: {package}")
        run([compiler(), *flags, f"-FU{package_units}", f"-FE{programs}", str(package)], timeout=300)
    run([compiler(), *flags, f"-Fu{COMPONENTS['common']['source']}", f"-Fu{package_units}",
         f"-FU{units}", f"-FE{programs}", str(source.relative_to(ROOT))], timeout=300)
    return programs / source.stem


def run_tests(component: str) -> None:
    role = component
    if component in ("client", "server"):
        build("common")
    build(role)
    output_component = f"{component}-test"
    runner = {
        "common": "test/common/Http2.Common.RunTests.pas",
        "client": "test/client/Http2.Client.RunTests.pas",
        "server": "test/server/Http2.Server.RunTests.pas",
    }[component]
    binary = compile_file(ROOT / runner, output_component, tests=True)
    if not binary.exists():
        raise SystemExit(f"Test runner did not produce {binary}")
    run_suite(binary, component in ("client", "server"))


def run_api_tests() -> None:
    runner = ROOT / "test/api/Http2.Api.RunTests.pas"
    binary = compile_file(runner, "api-test", tests=True)
    if not binary.exists():
        raise SystemExit(f"Test runner did not produce {binary}")
    run_suite(binary, True)
    probes = [ROOT / "test/common/Http2.Common.ApiProbe.pas",
              *sorted((ROOT / "test/api").glob("*.ApiProbe.pas"))]
    for probe in probes:
        component = "common-test" if probe.parent.name == "common" else "api-test"
        program = compile_file(probe, component, tests=True)
        run([str(program)], env=open_ssl_env(), timeout=30)


def run_integration_tests() -> None:
    binary = compile_file(ROOT / "test/integration/Http2.Integration.RunTests.pas",
                          "integration-test", tests=True)
    generated = ROOT / "bin" / target_name() / profile() / "integration-test"
    with tempfile.TemporaryDirectory(prefix="pki-", dir=generated) as directory:
        env = open_ssl_env()
        if platform.system() == "Darwin":
            openssl_bin = Path(env.get("OPENSSL_LIBPATH", "")).parent / "bin"
            if (openssl_bin / "openssl").exists():
                env["PATH"] = str(openssl_bin) + os.pathsep + env.get("PATH", "")
        run(["sh", "tools/server/certs/make_mtls_pki.sh", directory], env=env, timeout=30)
        env["HTTP2_TEST_PKI"] = directory
        run_suite(binary, True, env)
    run([sys.executable, "tools/check/local_process.py"])


def run_server_live(kind: str) -> None:
    sources = {
        "tls-live": ROOT / "test/integration/server/tls/Http2.Server.TlsLive.pas",
        "mtls-live": ROOT / "test/integration/server/mtls/Http2.Server.MtlsLive.pas",
    }
    if kind not in sources:
        raise SystemExit(f"Unknown server live gate: {kind}")
    build("common")
    build("client")
    build("server")
    binary = compile_file(sources[kind], "integration-test", tests=True)
    generated = binary.parent / f"{kind}-pki"
    generated.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="pki-", dir=generated) as directory:
        env = open_ssl_env()
        if platform.system() == "Darwin":
            openssl_bin = Path(env.get("OPENSSL_LIBPATH", "")).parent / "bin"
            if (openssl_bin / "openssl").exists():
                env["PATH"] = str(openssl_bin) + os.pathsep + env.get("PATH", "")
        run(["sh", "tools/server/certs/make_mtls_pki.sh", directory],
            env=env, timeout=30)
        run([str(binary), directory], env=env, timeout=180)


def compile_client_test_runner() -> Path:
    build("common")
    build("client")
    return compile_file(ROOT / "test/client/Http2.Client.RunTests.pas",
                        "client-test", tests=True)


def compile_server_examples() -> None:
    sources: list[Path] = []
    for source in sorted((ROOT / "examples/server").rglob("*.pas")):
        declaration = re.search(r"(?i)\bprogram\s+([A-Za-z_][A-Za-z0-9_.]*)",
                                strip_pascal(source.read_text(errors="replace")))
        if declaration:
            sources.append(source)
    if not sources:
        raise SystemExit("No server example programs are present")
    build("common")
    build("server")
    for source in sources:
        compile_file(source, "examples-server")


def validate_fast() -> None:
    for component in ("common", "client", "server"):
        run_tests(component)
    run_api_tests()
    run_integration_tests()
    for kind in ("source", "docs", "version"):
        check(kind)
    packages_check()


CLIENT_GATES = {
    "sanity": ("tools/client/validate/h2probe-sanity.sh",),
    "interop": ("tools/client/validate/interop.sh",),
    "harness": ("tools/client/validate/harness.sh",),
    "sse": ("tools/client/validate/sse-live.sh",),
    "proxy": ("tools/client/validate/proxy-live.sh",),
    "proxy:real": ("tools/client/validate/proxy-real.sh",),
    "websocket": ("tools/client/validate/websocket-live.sh", "live"),
    "websocket:autobahn": ("tools/client/validate/websocket-live.sh", "autobahn"),
    "cleartext": ("tools/client/validate/cleartext-live.sh",),
    "mtls": ("tools/client/validate/mtls-live.sh",),
    "mtls:real": ("tools/client/validate/mtls-real.sh",),
}

SERVER_GATES = {
    "conformance": ("tools/server/validate/run.sh", "conformance"),
    "fast": ("tools/server/validate/run.sh", "fast"),
    "tls:live": None,
    "mtls:live": None,
    "websocket": ("tools/server/validate/run.sh", "websocket"),
    "websocket:h2": ("tools/server/validate/run.sh", "websocket:h2"),
    "sse": ("tools/server/validate/run.sh", "sse"),
    "abuse": ("tools/server/validate/run.sh", "abuse"),
}


def run_validation_gate(role: str, gate: str) -> None:
    if role == "client":
        mapping = CLIENT_GATES
    elif role == "server":
        mapping = SERVER_GATES
    else:
        raise SystemExit(f"Unknown validation role: {role}")
    if gate not in mapping:
        raise SystemExit(f"Unknown {role} validation gate: {gate}")
    entry = mapping[gate]
    if role == "server" and gate in ("tls:live", "mtls:live"):
        run_server_live(gate.replace(":", "-"))
    else:
        assert entry is not None
        script = ROOT / entry[0]
        required(script, f"{role} validation script")
        if role == "server":
            compile_server_examples()
            env = dict(os.environ)
            env["SERVER_BIN"] = str(ROOT / "bin" / target_name() / profile()
                                    / "examples-server" / "programs")
            run(["sh", str(script), *entry[1:]], env=env)
        else:
            if gate in ("sse", "proxy", "websocket"):
                compile_client_test_runner()
            run(["bash", str(script), *entry[1:]])


def validate_all() -> None:
    validate_fast()
    for gate in CLIENT_GATES:
        run_validation_gate("client", gate)
    for gate in SERVER_GATES:
        run_validation_gate("server", gate)


def run_suite(binary: Path, needs_openssl: bool = False,
              env_override: dict[str, str] | None = None,
              timeout: int | None = None,
              cwd: Path = ROOT) -> None:
    env = open_ssl_env() if needs_openssl else dict(os.environ)
    if env_override:
        env.update(env_override)
    suite = os.environ.get("TEST_SUITE")
    args = [str(binary), *( [f"--suite={suite}"] if suite else ["--all"]),
            "--format=plain", "--sparse"]
    print("+ " + shlex.join(args), flush=True)
    try:
        timeout_seconds = timeout if timeout is not None else int(os.environ.get("TEST_TIMEOUT", "180"))
        if timeout_seconds < 1:
            raise ValueError
    except ValueError:
        raise SystemExit("TEST_TIMEOUT must be a positive number of seconds")
    print(f"Test start (UTC): {datetime.now(timezone.utc).isoformat()}; "
          f"limit: {timeout_seconds}s", flush=True)
    started = time.monotonic()
    proc = subprocess.Popen(args, cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            start_new_session=True)
    try:
        stdout, _ = proc.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            stdout, _ = proc.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            stdout, _ = proc.communicate()
        if stdout:
            print(stdout, end="", flush=True)
        print(f"Test elapsed: {time.monotonic() - started:.3f}s (timeout)", flush=True)
        raise SystemExit(f"Test run exceeded TEST_TIMEOUT={timeout_seconds}s; process group stopped")
    print(stdout, end="", flush=True)
    print(f"Test elapsed: {time.monotonic() - started:.3f}s; "
          f"child exit: {proc.returncode}", flush=True)
    if proc.returncode:
        if proc.returncode < 0:
            signum = -proc.returncode
            print(f"Test runner terminated by {signal.Signals(signum).name}", flush=True)
            raise SystemExit(128 + signum)
        raise SystemExit(proc.returncode)
    match = re.search(r"Number of run tests:\s*(\d+)", stdout)
    standalone = re.search(r"(?m)^PASS\s+(\d+)\s+cases?\s*$", stdout)
    if not ((match and int(match.group(1)) > 0) or
            (standalone and int(standalone.group(1)) > 0)):
        raise SystemExit("Test runner reported no registered tests; empty suite cannot pass")


def setup_checkout(url: str, relpath: str, pin: str, local: Path | None = None) -> None:
    path = ROOT / relpath
    resolved = path.resolve()
    if resolved != ROOT and ROOT not in resolved.parents:
        raise SystemExit(f"Setup target must stay inside this worktree: {relpath}")
    path.parent.mkdir(parents=True, exist_ok=True)
    if not (path / ".git").exists():
        if local and (local / ".git").exists():
            run(["git", "clone", "--local", "--no-hardlinks", str(local), str(path)])
        else:
            run(["git", "clone", url, str(path)])
    current = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"],
                                          cwd=ROOT, text=True).strip()
    if current != pin:
        run(["git", "-C", str(path), "fetch", "--all", "--tags"])
        run(["git", "-C", str(path), "checkout", pin])
    run(["git", "-C", str(path), "remote", "set-url", "origin", url])
    print(f"Pinned {relpath} at {pin}")


def setup_deps() -> None:
    cache = os.environ.get("TLS_DEPENDENCY_CACHE_ROOT")
    for name, (url, pin) in DEPENDENCIES.items():
        local = Path(cache).expanduser() / name if cache else None
        setup_checkout(url, "third_party/" + name, pin, local)
    for name in DEPENDENCIES:
        verify_dependency(name)


def setup_harness() -> None:
    setup_checkout("https://github.com/nomadlabsinc/h2-client-test-harness.git",
                   "third_party/h2-client-test-harness", HARNESS_REV)


def check(kind: str) -> None:
    run([sys.executable, "tools/check/repository.py", kind])
    if kind == "source":
        run([sys.executable, "tools/check/test_accounting.py"])


def packages_check() -> None:
    for dependency in DEPENDENCIES:
        verify_dependency(dependency)
    run([sys.executable, "tools/packages.py", "--check"])
    check("packages")
    packages = sorted(path for component in ("common", "client", "server", "openssl", "tlslib")
                      for path in (ROOT / COMPONENTS[component]["package_dir"]).glob("*.lpk"))
    if not packages:
        raise SystemExit("No Lazarus packages are present")
    lazbuild = os.environ.get("LAZBUILD", "lazbuild")
    if not shutil.which(lazbuild):
        raise SystemExit("lazbuild is required to build the package files")
    cpu = subprocess.check_output([compiler(), "-iTP"], text=True).strip()
    os_name = subprocess.check_output([compiler(), "-iTO"], text=True).strip()
    compiler_ids = {"aarch64": "ppca64", "x86_64": "ppcx64", "i386": "ppc386", "arm": "ppcarm"}
    compiler_id = compiler_ids.get(cpu.casefold())
    if not compiler_id:
        raise SystemExit(f"No Lazarus compiler ID is configured for CPU {cpu}")
    pcp = ROOT / "bin" / target_name() / profile() / "lazarus-config"
    pcp.mkdir(parents=True, exist_ok=True)
    order = {"http2common": 0, "http2openssl": 1, "http2tlslib": 2,
             "http2client": 3, "http2server": 4, "http2clientreaders": 5}
    packages.sort(key=lambda path: order.get(path.stem.casefold(), 10))
    try:
        for package in packages:
            stem = package.stem
            component = PACKAGE_COMPONENT[stem]
            if stem == "http2clientreaders":
                component = "readers"
            if component == "tlslib":
                build("tlslib")
            units, programs = output(f"package-{stem}")
            common_build_units = f"-Fu{ROOT / 'bin' / target_name() / profile() / 'common' / 'units'}"
            options = [flag for flag in base_flags(component) if flag != common_build_units]
            if component != "common":
                options.insert(1, f"-Fu{ROOT / 'bin' / target_name() / profile() / 'package-http2common' / 'units'}")
            if component == "readers":
                options.insert(2, f"-Fu{ROOT / 'bin' / target_name() / profile() / 'package-http2client' / 'units'}")
            options.extend((f"-FU{units}", f"-FE{programs}"))
            args = [lazbuild, "--build-all", f"--pcp={pcp}", f"--cpu={cpu}",
                    f"--os={os_name}", f"--compiler={compiler_id}"]
            args.extend(f"--opt={flag}" for flag in options)
            args.append(str(package.relative_to(ROOT)))
            run(args, env=open_ssl_env() if component in ("client", "server", "readers", "openssl") else None)
    finally:
        run([sys.executable, "tools/packages.py"])

def examples() -> None:
    roots = ("examples/client", "examples/server", "examples/integration")
    programs: list[tuple[Path, str]] = []
    for name in roots:
        role = name.split("/", 1)[1]
        for source in (ROOT / name).rglob("*.pas") if (ROOT / name).exists() else []:
            declaration = re.search(r"(?i)\bprogram\s+([A-Za-z_][A-Za-z0-9_.]*)",
                                    strip_pascal(source.read_text(errors="replace")))
            if declaration:
                programs.append((source, role))
    if not programs:
        raise SystemExit("No example programs are present; M09 supplies them")
    build("common")
    roles = {role for _, role in programs}
    if "client" in roles or "integration" in roles:
        build("client")
    if "server" in roles or "integration" in roles:
        build("server")
    for source, role in programs:
        compile_file(source, f"examples-{role}")


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python3 tools/build.py <target>")
    target = sys.argv[1].replace("-", ":").replace("_", ":")
    if target == "setup:deps":
        setup_deps()
    elif target == "setup:harness":
        setup_harness()
    elif target == "build:common":
        build("common")
    elif target.startswith("component:build:"):
        component = target.removeprefix("component:build:")
        if component not in ("common", "client", "server", "readers"):
            raise SystemExit(f"Unknown build component: {component}")
        build(component)
    elif target in ("build:openssl", "build:tlslib"):
        provider = target.split(":", 1)[1]
        build(provider)
    elif target == "build:client":
        build("common")
        build("client")
    elif target == "build:server":
        build("common")
        build("server")
    elif target == "build:readers":
        build("common")
        build("client")
        build("readers")
    elif target == "build":
        build("common")
        build("client")
        build("server")
    elif target.startswith("test:") and target.split(":", 1)[1] in ("common", "client", "server"):
        run_tests(target.split(":", 1)[1])
    elif target == "test":
        for component in ("common", "client", "server"):
            run_tests(component)
    elif target == "source:check":
        check("source")
    elif target == "docs:check":
        check("docs")
    elif target == "version:check":
        check("version")
    elif target == "packages:check":
        packages_check()
    elif target == "examples":
        examples()
    elif target == "test:api":
        run_api_tests()
    elif target == "test:integration":
        run_integration_tests()
    elif target in ("test:tls:contract", "test:tls:openssl", "test:tls:tlslib",
                    "test:tls:client", "test:tls:integration"):
        suite = target.removeprefix("test:tls:")
        runners = {
            "contract": ROOT / "test/common/Http2.Common.Tls.Contract.Run.pas",
            "openssl": ROOT / "test/tls/openssl/Http2.Tls.OpenSSL.Tests.pas",
            "tlslib": ROOT / "test/tls/tlslib/Http2.Tls.TlsLib.Tests.pas",
            "client": ROOT / "test/client/Http2.Client.Tls.Session.Runner.pas",
            "integration": ROOT / "test/integration/tls/Http2.Tls.Integration.Tests.pas",
        }
        source = runners[suite]
        required(source, f"bounded TLS {suite} runner (owned by TLS-03/05/06/09)")
        owners = {"contract": "common-test", "openssl": "openssl-test", "tlslib": "tlslib-test",
                  "client": "tls-client-test", "integration": "tls-integration-test"}
        if suite == "contract":
            build("common")
        elif suite == "openssl":
            build("common")
            build("openssl")
        elif suite == "tlslib":
            build("common")
            build("tlslib")
        elif suite == "client":
            build("common")
            build("client")
        else:
            build("common")
            build("openssl")
            build("tlslib")
        binary = compile_file(source, owners[suite], tests=True)
        run_directory = output(owners[suite])[1]
        run_suite(binary, suite in ("openssl", "integration"), timeout=30,
                  cwd=run_directory)
    elif target == "validate:fast":
        validate_fast()
    elif target == "validate":
        validate_all()
    elif target.startswith("validate:client:"):
        run_validation_gate("client", target.removeprefix("validate:client:"))
    elif target.startswith("validate:server:"):
        run_validation_gate("server", target.removeprefix("validate:server:"))
    elif target == "clean":
        shutil.rmtree(ROOT / "bin", ignore_errors=True)
    elif target.startswith("clean:component:"):
        component = target.removeprefix("clean:component:")
        if component not in ("common", "client", "server", "readers", "openssl", "tlslib"):
            raise SystemExit(f"Unknown clean component: {component}")
        package_outputs = {
            "common": ("common", "common-test", "package-http2common"),
            "client": ("client", "readers", "tls-client-test", "package-http2client", "package-http2clientreaders"),
            "readers": ("readers", "package-http2clientreaders"),
            "server": ("server", "package-http2server"),
            "openssl": ("openssl", "openssl-test", "package-http2openssl"),
            "tlslib": ("tlslib", "tlslib-test", "package-http2tlslib"),
        }[component]
        for output_component in package_outputs:
            shutil.rmtree(ROOT / "bin" / target_name() / profile() / output_component,
                          ignore_errors=True)
    else:
        raise SystemExit(f"Unknown build target: {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
