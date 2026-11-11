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
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.check.repository import strip_pascal  # noqa: E402

MORMOT_REV = "b2b195da1e0580058672a88620ef71bb47283eb1"
HARNESS_REV = "0bc075cc21e5a247dfd222e005d1e7e5679d2bff"


def run(args: list[str], *, env: dict[str, str] | None = None, cwd: Path = ROOT,
        timeout: int | None = None) -> None:
    print("+ " + shlex.join(args), flush=True)
    try:
        result = subprocess.run(args, cwd=cwd, env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise SystemExit(f"Command exceeded its {timeout}s deadline: {shlex.join(args)}")
    if result.returncode:
        raise SystemExit(result.returncode)


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
    if role.startswith("examples-"):
        role = "examples"
    flags = ["-O2", "-vw", "-Mdelphi", "-Fu./src"]
    if role in ("client", "server", "readers", "examples", "api", "integration"):
        verify_mormot()
        mormot = Path(os.environ.get("MORMOT", "third_party/mORMot2/src"))
        for part in ("core", "lib", "net", "crypt"):
            flags.append(f"-Fu{mormot / part}")
        flags.append(f"-Fu{ROOT / 'bin' / target_name() / profile() / 'common' / 'units'}")
    if role == "examples":
        flags.extend(("-Fu./examples", "-Fu./examples/client", "-Fu./examples/server",
                      "-Fu./examples/integration"))
    if tests:
        unit_root = fpc_unit_root()
        flags.append(f"-Fu{Path(unit_root) / 'fcl-fpcunit'}")
        flags.extend(("-Fu./test", "-Fu./test/common", "-Fu./test/client",
                      "-Fu./test/server", "-Fu./test/api", "-Fu./test/integration", "-Fu./examples", "-Fu./examples/client",
                      "-Fu./examples/server"))
    flags.extend(shlex.split(os.environ.get("FPCFLAGS", "")))
    return flags


def verify_mormot() -> None:
    source = Path(os.environ.get("MORMOT", "third_party/mORMot2/src"))
    repo = source if (source / ".git").exists() else source.parent
    if not (repo / ".git").exists():
        raise SystemExit("Pinned mORMot2 is missing; run setup:deps or set MORMOT to a pinned read-only checkout")
    try:
        current = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"],
                                          cwd=ROOT, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        raise SystemExit(f"Cannot read mORMot2 revision at {repo}")
    if current != MORMOT_REV:
        raise SystemExit(f"mORMot2 revision is {current}; expected {MORMOT_REV}")


def compile_file(source: Path, component: str, *, tests: bool = False) -> Path:
    source = required(source, f"{component} source")
    units, programs = output(component)
    args = [compiler(), *base_flags(component, tests=tests),
            f"-FU{units}", f"-FE{programs}", str(source.relative_to(ROOT))]
    uses_tls = component in ("client", "server", "readers", "examples", "api-test", "integration-test") or component.startswith("examples-")
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
    facade = {
        "common": "src/Http2.Common.pas",
        "client": "src/Http2.Client.pas",
        "server": "src/Http2.Server.pas",
        "readers": "src/Http2.Client.Readers.pas",
    }[component]
    compile_file(ROOT / facade, component)


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


def run_suite(binary: Path, needs_openssl: bool = False,
              env_override: dict[str, str] | None = None) -> None:
    env = open_ssl_env() if needs_openssl else dict(os.environ)
    if env_override:
        env.update(env_override)
    suite = os.environ.get("TEST_SUITE")
    args = [str(binary), *( [f"--suite={suite}"] if suite else ["--all"]),
            "--format=plain", "--sparse"]
    print("+ " + shlex.join(args), flush=True)
    try:
        timeout_seconds = int(os.environ.get("TEST_TIMEOUT", "180"))
        if timeout_seconds < 1:
            raise ValueError
    except ValueError:
        raise SystemExit("TEST_TIMEOUT must be a positive number of seconds")
    proc = subprocess.Popen(args, cwd=ROOT, env=env, text=True,
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
        raise SystemExit(f"Test run exceeded TEST_TIMEOUT={timeout_seconds}s; process group stopped")
    print(stdout, end="", flush=True)
    if proc.returncode:
        raise SystemExit(proc.returncode)
    match = re.search(r"Number of run tests:\s*(\d+)", stdout)
    if not match or int(match.group(1)) == 0:
        raise SystemExit("Test runner reported no registered tests; empty suite cannot pass")


def setup_checkout(url: str, relpath: str, pin: str) -> None:
    path = ROOT / relpath
    resolved = path.resolve()
    if resolved != ROOT and ROOT not in resolved.parents:
        raise SystemExit(f"Setup target must stay inside this worktree: {relpath}")
    path.parent.mkdir(parents=True, exist_ok=True)
    if not (path / ".git").exists():
        run(["git", "clone", url, str(path)])
    current = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"],
                                          cwd=ROOT, text=True).strip()
    if current != pin:
        run(["git", "-C", str(path), "fetch", "--all", "--tags"])
        run(["git", "-C", str(path), "checkout", pin])
    print(f"Pinned {relpath} at {pin}")


def setup_deps() -> None:
    setup_checkout("https://github.com/synopse/mORMot2.git", "third_party/mORMot2", MORMOT_REV)


def setup_harness() -> None:
    setup_checkout("https://github.com/nomadlabsinc/h2-client-test-harness.git",
                   "third_party/h2-client-test-harness", HARNESS_REV)


def check(kind: str) -> None:
    run([sys.executable, "tools/check/repository.py", kind])


def packages_check() -> None:
    run([sys.executable, "tools/packages.py", "--check"])
    check("packages")
    packages = sorted(ROOT.glob("*.lpk"))
    if not packages:
        raise SystemExit("No Lazarus packages are present")
    lazbuild = os.environ.get("LAZBUILD", "lazbuild")
    if not shutil.which(lazbuild):
        raise SystemExit("lazbuild is required to build the package files")
    cpu = subprocess.check_output([compiler(), "-iTP"], text=True).strip()
    os_name = subprocess.check_output([compiler(), "-iTO"], text=True).strip()
    compiler_ids = {"aarch64": "ppca64", "x86_64": "ppcx64", "i386": "ppc386",
                    "arm": "ppcarm"}
    compiler_id = compiler_ids.get(cpu.casefold())
    if not compiler_id:
        raise SystemExit(f"No Lazarus compiler ID is configured for CPU {cpu}")
    pcp = ROOT / "bin" / target_name() / profile() / "lazarus-config"
    pcp.mkdir(parents=True, exist_ok=True)
    order = {"http2common": 0, "http2client": 1, "http2server": 2,
             "http2clientreaders": 3}
    packages.sort(key=lambda p: order.get(p.stem.casefold(), 10))
    for package in packages:
        stem = package.stem
        component = ("common" if "common" in stem else
                     "server" if "server" in stem else
                     "readers" if "readers" in stem else "client")
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
        try:
            run(args, env=open_ssl_env() if component != "common" else None)
        finally:
            # Lazarus regenerates package sources without the required header.
            # Restore the canonical equivalent sources after each build.
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


def incomplete(label: str, detail: str) -> None:
    raise SystemExit(f"{label} is not ready: {detail}")


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
    elif target in ("validate:fast", "validate"):
        incomplete(target, "required integration and API probes are supplied by later stories")
    elif target.startswith("validate:"):
        incomplete(target, "the source validation gates arrive with M09")
    elif target == "clean":
        shutil.rmtree(ROOT / "bin", ignore_errors=True)
    else:
        raise SystemExit(f"Unknown build target: {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
