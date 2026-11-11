#!/usr/bin/env python3
"""Compile and link the macOS CryptoLib random-provider probe; do not run it."""
from __future__ import annotations

import os
import shlex
import subprocess
from pathlib import Path

HTTP2_ROOT = Path(os.environ.get("HTTP2_ROOT", Path(__file__).resolve().parents[4])).resolve()


def dependency(name: str) -> Path:
    key = name.upper() + "_ROOT"
    value = os.environ.get(key)
    if not value:
        raise SystemExit(f"{key} must name the pinned dependency checkout")
    root = Path(value).resolve()
    if not root.is_dir():
        raise SystemExit(f"dependency root does not exist: {root}")
    return root


def main() -> int:
    output = Path(os.environ.get("TLS10_RNG_OUTPUT", HTTP2_ROOT / "bin/tls10-rng-probe")).resolve()
    units = output / "units"
    binaries = output / "programs"
    units.mkdir(parents=True, exist_ok=True)
    binaries.mkdir(parents=True, exist_ok=True)

    cryptolib = dependency("cryptolib4pascal")
    hashlib = dependency("hashlib4pascal")
    simplebase = dependency("simplebaselib4pascal")
    tlslib = dependency("tlslib4pascal")
    overlay_module = HTTP2_ROOT / "tools/patches/cryptolib/overlay.py"
    import importlib.util

    spec = importlib.util.spec_from_file_location("cryptolib_rng_overlay", overlay_module)
    if spec is None or spec.loader is None:
        raise SystemExit("cannot load CryptoLib overlay helper")
    overlay = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(overlay)
    provider_dir = overlay.prepare_macos_rng_overlay(cryptolib, output / "overlay")

    search_paths = [provider_dir, output / "overlay/CryptoLib/src/Include"]
    for root in (cryptolib, hashlib, simplebase, tlslib):
        search_paths.extend(sorted({source.parent for source in root.rglob("*.pas")}))
    command = [
        os.environ.get("FPC", "fpc"), "-Mdelphi", "-O2", "-vw",
        f"-FU{units}", f"-FE{binaries}", "-otls10_rng_probe",
        *(f"-Fu{path}" for path in search_paths),
        str(HTTP2_ROOT / "tools/studies/tls/rng/Tls10.MacOSRandomProvider.Probe.pas"),
    ]
    print("Compile/link command:")
    print(shlex.join(command))
    print(f"Overlay fingerprint: {overlay.macos_rng_overlay_fingerprint()}")
    subprocess.run(command, cwd=HTTP2_ROOT, check=True)
    print(f"Linked probe: {binaries / 'tls10_rng_probe'}")
    print("The probe was not executed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
