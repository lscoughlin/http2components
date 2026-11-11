"""Shared component and package paths for source and build tools."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

COMPONENTS = {
    "common": {"source": "common/src", "package_dir": "common", "facade": "common/src/Http2.Common.pas",
               "packages": ("http2common",)},
    "client": {"source": "client/src", "package_dir": "client", "facade": "client/src/Http2.Client.pas",
               "packages": ("http2client", "http2clientreaders")},
    "server": {"source": "server/src", "package_dir": "server", "facade": "server/src/Http2.Server.pas",
               "packages": ("http2server",)},
    "openssl": {"source": "tls/openssl/src", "package_dir": "tls/openssl", "facade": None,
                "packages": ("http2openssl",)},
    "tlslib": {"source": "tls/tlslib/src", "package_dir": "tls/tlslib", "facade": None,
               "packages": ("http2tlslib",)},
}

PACKAGE_COMPONENT = {
    package: component
    for component, details in COMPONENTS.items()
    for package in details["packages"]
}


def source_dirs(root: Path = ROOT) -> list[Path]:
    """Return every required existing source directory, or fail clearly."""
    result = []
    for name, details in COMPONENTS.items():
        path = root / details["source"]
        if not path.is_dir():
            # Provider skeletons are owned by TLS-04 and are not present yet.
            if name in ("openssl", "tlslib") and not any(
                    (root / "tls" / name / (package + ".lpk")).exists()
                    for package in details["packages"]):
                continue
            raise SystemExit(f"Required component source directory is missing: {details['source']}")
        result.append(path)
    return result
