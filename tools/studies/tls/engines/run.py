#!/usr/bin/env python3
"""Compile and run bounded TLS engine studies with isolated output."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
STUDY = Path(__file__).resolve().parent
OUT = ROOT / "bin" / "studies" / "tls-engines"
UNITS = OUT / "units"
TLS_UNITS = UNITS / "tlslib"
OPENSSL_UNITS = UNITS / "openssl"
PROGRAMS = OUT / "programs"
THIRD = ROOT / "third_party"
LOCAL_MORMOT = ROOT / "third_party" / "mORMot2" / "src"
MORMOT = Path(os.environ.get("MORMOT", str(LOCAL_MORMOT)))
OPENSSL_LIBPATH = os.environ.get("OPENSSL_LIBPATH", "/opt/homebrew/opt/openssl@3/lib")


def run(args: list[str], *, timeout: int, env: dict[str, str] | None = None,
        log: Path | None = None) -> None:
    if log is None:
        print("+ " + " ".join(args), flush=True)
        subprocess.run(args, cwd=ROOT, env=env, check=True, timeout=timeout)
        return
    result = subprocess.run(args, cwd=ROOT, env=env, timeout=timeout,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_text(result.stdout)
    print(f"+ {args[0]} {args[-1]} (log: {log.relative_to(ROOT)})", flush=True)
    if result.returncode:
        print(result.stdout[-12000:], file=sys.stderr, flush=True)
        raise subprocess.CalledProcessError(result.returncode, args)


def tlslib_unit_flags() -> list[str]:
    roots = [
        THIRD / "TlsLib4Pascal" / "TlsLib" / "src",
        THIRD / "CryptoLib4Pascal" / "CryptoLib" / "src",
        THIRD / "HashLib4Pascal" / "HashLib" / "src",
        THIRD / "SimpleBaseLib4Pascal" / "SimpleBaseLib" / "src",
    ]
    dirs: set[Path] = set()
    includes: set[Path] = set()
    for base in roots:
        for source in base.rglob("*.pas"):
            dirs.add(source.parent)
        for include in base.rglob("*.inc"):
            includes.add(include.parent)
    # Keep the dependency's low-level provider directories before the full
    # source search path so their unit names resolve deterministically.
    preferred = [
        THIRD / "CryptoLib4Pascal" / "CryptoLib" / "src" / "Math" / "EC" / "Multiplier",
        THIRD / "CryptoLib4Pascal" / "CryptoLib" / "src" / "Math" / "EC",
    ]
    dirs = set(preferred) | dirs
    flags = [f"-Fu{path}" for path in preferred]
    flags.extend(f"-Fu{path}" for path in sorted(dirs - set(preferred)))
    # Nested {$I ../../Include/...} paths in the pinned HashLib source resolve
    # from its Pascal unit directory, so keep those directories on both paths.
    includes.update(dirs)
    flags.extend(f"-Fi{path}" for path in sorted(includes))
    return flags


def compile_program(name: str, flags: list[str], units: Path,
                    extra: list[str] = ()) -> Path:
    source = STUDY / name
    exe = PROGRAMS / source.stem
    args = ["fpc", "-Mdelphi", "-O1", "-vw", "-gl", *flags,
            f"-FU{units}", f"-FE{PROGRAMS}", *extra, str(source)]
    run(args, timeout=120, log=OUT / f"{source.stem}.compile.log")
    return exe


def compile_dependency_unit(source: Path, flags: list[str], units: Path) -> None:
    args = ["fpc", "-Mdelphi", "-O1", "-vw", "-gl", *flags,
            f"-FU{units}", f"-FE{PROGRAMS}", str(source)]
    run(args, timeout=120, log=OUT / f"{source.stem}.compile.log")


def main() -> None:
    TLS_UNITS.mkdir(parents=True, exist_ok=True)
    OPENSSL_UNITS.mkdir(parents=True, exist_ok=True)
    PROGRAMS.mkdir(parents=True, exist_ok=True)
    root_cert = OUT / "root-cert.pem"
    root_key = OUT / "root-key.pem"
    bad_root_cert = OUT / "bad-root-cert.pem"
    bad_root_key = OUT / "bad-root-key.pem"
    intermediate_cert = OUT / "intermediate-cert.pem"
    intermediate_key = OUT / "intermediate-key.pem"
    server_cert = OUT / "server-cert.pem"
    server_key = OUT / "server-key.pem"
    server_chain = OUT / "server-chain.pem"
    client_cert = OUT / "client-cert.pem"
    client_key = OUT / "client-key.pem"
    client_chain = OUT / "client-chain.pem"
    intermediate_csr = OUT / "intermediate.csr"
    server_csr = OUT / "server.csr"
    client_csr = OUT / "client.csr"
    server_ext = OUT / "server.ext"
    client_ext = OUT / "client.ext"
    intermediate_ext = OUT / "intermediate.ext"
    server_ext.write_text(
        "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
        "extendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n")
    client_ext.write_text(
        "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
        "extendedKeyUsage=clientAuth\nsubjectAltName=DNS:client.local\n")
    intermediate_ext.write_text(
        "basicConstraints=critical,CA:TRUE,pathlen:0\n"
        "keyUsage=critical,keyCertSign,cRLSign\n")
    fixture_env = {**os.environ, "OPENSSL_CONF": "/dev/null"}
    for subject, cert, key in (("/CN=study-root", root_cert, root_key),
                               ("/CN=bad-root", bad_root_cert, bad_root_key)):
        run(["openssl", "req", "-quiet", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
             "-subj", subject, "-addext", "basicConstraints=critical,CA:TRUE",
             "-addext", "keyUsage=critical,keyCertSign,cRLSign", "-keyout", str(key),
             "-out", str(cert)], timeout=30, env=fixture_env)
    for subject, key, csr in (("/CN=study-intermediate", intermediate_key, intermediate_csr),
                              ("/CN=localhost", server_key, server_csr),
                              ("/CN=client.local", client_key, client_csr)):
        run(["openssl", "req", "-quiet", "-new", "-newkey", "rsa:2048", "-nodes",
             "-subj", subject, "-keyout", str(key), "-out", str(csr)],
            timeout=30, env=fixture_env)
    for csr, issuer_cert, issuer_key, serial_file, ext, cert in (
            (intermediate_csr, root_cert, root_key, OUT / "root.srl", intermediate_ext,
             intermediate_cert),
            (server_csr, intermediate_cert, intermediate_key, OUT / "intermediate.srl",
             server_ext, server_cert),
            (client_csr, intermediate_cert, intermediate_key, OUT / "intermediate.srl",
             client_ext, client_cert)):
        run(["openssl", "x509", "-req", "-in", str(csr), "-CA", str(issuer_cert),
             "-CAkey", str(issuer_key), "-CAserial", str(serial_file), "-CAcreateserial",
             "-days", "2", "-sha256", "-extfile", str(ext), "-out", str(cert)],
            timeout=30, env=fixture_env)
    server_chain.write_bytes(server_cert.read_bytes() + intermediate_cert.read_bytes())
    client_chain.write_bytes(client_cert.read_bytes() + intermediate_cert.read_bytes())
    tls_flags = tlslib_unit_flags()
    for package in (
        THIRD / "HashLib4Pascal" / "HashLib" / "src" / "Packages" / "FPC" /
        "HashLib4PascalPackage.pas",
        THIRD / "SimpleBaseLib4Pascal" / "SimpleBaseLib" / "src" / "Packages" / "FPC" /
        "SimpleBaseLib4PascalPackage.pas",
        THIRD / "CryptoLib4Pascal" / "CryptoLib" / "src" / "Packages" / "FPC" /
        "CryptoLib4PascalPackage.pas",
    ):
        compile_dependency_unit(package, tls_flags, TLS_UNITS)
    tlslib = compile_program("tlslib_engine_study.pas", tls_flags, TLS_UNITS)
    openssl_flags = [f"-Fu{MORMOT / part}" for part in ("core", "lib", "net", "crypt")]
    openssl = compile_program("openssl_memory_bio_study.pas", openssl_flags,
                              OPENSSL_UNITS,
                              ["-dUSE_OPENSSL"])
    if "--compile-only" in sys.argv:
        return
    run([str(tlslib), str(root_cert), str(bad_root_cert), str(server_chain), str(server_key),
         str(client_chain), str(client_key), str(intermediate_cert)], timeout=30)
    run([str(openssl), str(root_cert), str(server_chain), str(server_key),
         str(client_chain), str(client_key), str(intermediate_cert)], timeout=30,
        env={**os.environ, "OPENSSL_LIBPATH": OPENSSL_LIBPATH})


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"command failed with exit code {error.returncode}")
