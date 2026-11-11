"""Prepare the pinned CryptoLib macOS RNG overlay for package builds."""
from __future__ import annotations

import hashlib
import shutil
import subprocess
from pathlib import Path

CRYPTOLIB_REVISION = "f559d27462ddd149ef9d1880f97854a8a4cc8368"
SOURCE_SHA256 = "a6c5059e3602557eb26731689c88fca8a804ec3a21a2d369cb211dccec527d6a"
PATCH_SHA256 = "20f339b010d36638a903bc57451d9496e75a15106ab24e2def3617ec0f3235a8"
PATCHED_UNIT_SHA256 = "4b7f08330ee2ff61522c964d711f1346f1119aa1c52896a2bcca551196dec712"
PATCH_NAME = "tls-10-macos-rng.patch"
UNIT_REL = Path("CryptoLib/src/Rngs/Providers/ClpMacOSRandomProvider.pas")
INCLUDE_REL = Path("CryptoLib/src/Include")


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def macos_rng_overlay_fingerprint() -> str:
    """Return the stable input fingerprint for build-cache invalidation."""
    patch = Path(__file__).with_name(PATCH_NAME)
    return hashlib.sha256(
        (CRYPTOLIB_REVISION + SOURCE_SHA256 + _sha256(patch)).encode("ascii")
    ).hexdigest()


def prepare_macos_rng_overlay(original_root: Path, output_root: Path) -> Path:
    """Return the provider-unit directory in a verified patched source overlay."""
    original_root = Path(original_root).resolve()
    output_root = Path(output_root).resolve()
    revision = subprocess.check_output(
        ["git", "-C", str(original_root), "rev-parse", "HEAD"], text=True
    ).strip()
    if revision != CRYPTOLIB_REVISION:
        raise RuntimeError(f"CryptoLib revision mismatch: {revision}")
    original_unit = original_root / UNIT_REL
    if _sha256(original_unit) != SOURCE_SHA256:
        raise RuntimeError("CryptoLib RNG source hash mismatch")
    patch_file = Path(__file__).with_name(PATCH_NAME).resolve()
    if PATCH_SHA256 and _sha256(patch_file) != PATCH_SHA256:
        raise RuntimeError("CryptoLib RNG patch hash mismatch")
    if output_root.exists():
        shutil.rmtree(output_root)
    provider_dir = output_root / UNIT_REL.parent
    provider_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(original_unit, provider_dir / UNIT_REL.name)
    shutil.copytree(original_root / INCLUDE_REL, output_root / INCLUDE_REL)
    subprocess.run(
        ["patch", "--batch", "--forward", "-p1", "-i", str(patch_file)],
        cwd=output_root,
        check=True,
    )
    patched = provider_dir / UNIT_REL.name
    if _sha256(patched) != PATCHED_UNIT_SHA256:
        raise RuntimeError("Patched CryptoLib RNG source hash mismatch")
    return provider_dir
