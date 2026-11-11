#!/usr/bin/env python3
"""Repository checks for http2components."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.components import COMPONENTS

ROOT = Path(os.environ.get("HTTP2_ROOT", Path(__file__).resolve().parents[2])).resolve()
LICENSE = "Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)"
COPYRIGHT = "Copyright 2026 Liam Seamus Coughlin"


class Checks:
    def __init__(self) -> None:
        self.errors: list[str] = []

    def fail(self, message: str) -> None:
        self.errors.append(message)
        print(f"FAIL {message}")

    def done(self) -> int:
        if self.errors:
            print(f"{len(self.errors)} check(s) failed")
            return 1
        print("All checks passed")
        return 0


def source_dirs() -> list[Path]:
    result = []
    for role, details in COMPONENTS.items():
        path = ROOT / COMPONENTS[role]["source"]
        if not path.is_dir():
            if role in ("openssl", "tlslib"):
                package_dir = ROOT / details["package_dir"]
                if not any(package_dir.glob("*.lpk")):
                    continue
            raise SystemExit(f"Required component source directory is missing: {path.relative_to(ROOT)}")
        result.append(path)
    return result


def package_files() -> list[Path]:
    return sorted(path for role in ("common", "client", "server", "openssl", "tlslib")
                  for path in (ROOT / COMPONENTS[role]["package_dir"]).glob("*.lpk"))


def pascal_files() -> list[Path]:
    result: list[Path] = []
    for area in ("test", "examples", "tools"):
        base = ROOT / area
        if base.exists():
            result.extend(p for p in base.rglob("*.pas") if p.is_file())
    for base in source_dirs():
        result.extend(p for p in base.rglob("*.pas") if p.is_file())
    return sorted(result)


def header_pascal_files() -> list[Path]:
    result = pascal_files()
    result.extend(p for p in ROOT.glob("*.pas") if p.is_file())
    result.extend(p for role in COMPONENTS
                  for p in (ROOT / COMPONENTS[role]["package_dir"]).glob("*.pas") if p.is_file())
    probes = ROOT / "doc/verification/client-probes"
    if probes.exists():
        result.extend(p for p in probes.glob("*.pas") if p.is_file())
    return sorted(set(result))


def strip_pascal(text: str) -> str:
    """Replace Pascal comments and string literals with spaces."""
    out = list(text)
    i = 0
    n = len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            if j < 0:
                j = n
            for k in range(i, j):
                out[k] = " "
            i = j
        elif text.startswith("(*", i) or text[i] == "{":
            end = "*)" if text.startswith("(*", i) else "}"
            start_len = 2 if end == "*)" else 1
            depth = 1
            j = i + start_len
            while j < n and depth:
                if end == "*)" and text.startswith("(*", j):
                    depth += 1
                    j += 2
                elif end == "*)" and text.startswith("*)", j):
                    depth -= 1
                    j += 2
                elif end == "}" and text[j] == "{":
                    depth += 1
                    j += 1
                elif end == "}" and text[j] == "}":
                    depth -= 1
                    j += 1
                else:
                    j += 1
            j = min(j, n)
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        elif text[i] == "'":
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            for k in range(i, min(j, n)):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        else:
            i += 1
    return "".join(out)


def tokens(code: str) -> list[str]:
    return re.findall(r"[A-Za-z_][A-Za-z0-9_.]*|:=|<=|>=|<>|[^\s]", code)


def parse_pascal(path: Path) -> tuple[str | None, list[tuple[str, str]]]:
    toks = tokens(strip_pascal(path.read_text(errors="replace")))
    lower = [t.lower() for t in toks]
    unit = None
    for i in range(len(toks) - 1):
        if lower[i] == "unit":
            unit = toks[i + 1]
            break
        if lower[i] == "program":
            break
    try:
        interface = lower.index("interface")
    except ValueError:
        edges: list[tuple[str, str]] = []
        i = 0
        while i < len(toks):
            if lower[i] == "uses":
                i += 1
                while i < len(toks) and toks[i] != ";":
                    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", toks[i]):
                        edges.append((toks[i], "implementation"))
                        i += 1
                        if i < len(toks) and lower[i] == "in":
                            i += 1
                        continue
                    i += 1
            i += 1
        return unit, edges
    try:
        implementation = lower.index("implementation", interface + 1)
    except ValueError:
        implementation = len(toks)
    edges: list[tuple[str, str]] = []
    for lo, hi, section in ((interface, implementation, "interface"),
                            (implementation, len(toks), "implementation")):
        i = lo
        while i < hi:
            if lower[i] != "uses":
                i += 1
                continue
            i += 1
            while i < hi and toks[i] != ";":
                if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", toks[i]):
                    name = toks[i]
                    edges.append((name, section))
                    i += 1
                    if i < hi and lower[i] == "in":
                        # The quoted file name was removed by the lexer.
                        # Keep the unit edge and skip the `in` marker.
                        i += 1
                        continue
                    if i < hi and toks[i] == ".":
                        i += 1
                    continue
                i += 1
            i += 1
    return unit, edges


def version_check(c: Checks) -> None:
    version_file = ROOT / "VERSION"
    if not version_file.exists():
        c.fail("VERSION is missing")
        return
    version = version_file.read_text().strip()
    if version != "0.30.0" or version_file.read_text() != "0.30.0\n":
        c.fail("VERSION must contain exactly 0.30.0 followed by one newline")
    lpk_files = package_files()
    for package in lpk_files:
        try:
            tree = ET.parse(package)
            version = tree.find(".//Version[@Major]")
            actual = ".".join(version.get(key, "") for key in ("Major", "Minor", "Release")) if version is not None else ""
            if version is not None and version.get("Build", "0") not in ("", "0"):
                actual += "." + version.get("Build", "")
        except ET.ParseError as error:
            c.fail(f"{package.name} is invalid XML: {error}")
            continue
        if actual != "0.30.0":
            c.fail(f"{package.name} declares version {actual or '<missing>'}; expected 0.30.0")
    print(f"Checked VERSION and {len(lpk_files)} package file(s)")


def source_check(c: Checks) -> None:
    files = pascal_files()
    header_files = header_pascal_files()
    if not header_files:
        c.fail("no maintained Pascal files exist")
        return
    units: dict[str, tuple[str, Path]] = {}
    parsed: dict[str, tuple[str, Path, str, list[tuple[str, str]]]] = {}
    for path in header_files:
        rel = path.relative_to(ROOT).as_posix()
        lines = path.read_text(errors="replace").splitlines()
        if len(lines) >= 1000:
            c.fail(f"{rel} has {len(lines)} lines; the maximum is 999")
    for path in files:
        rel = path.relative_to(ROOT).as_posix()
        code = strip_pascal(path.read_text(errors="replace"))
        kind_match = re.search(r"(?i)\b(unit|program)\s+([A-Za-z_][A-Za-z0-9_.]*)", code)
        if not kind_match:
            c.fail(f"{rel} has no unit or program declaration")
            continue
        kind, declared = kind_match.group(1).lower(), kind_match.group(2)
        if Path(rel).parts[0] in ("common", "client", "server", "tls"):
            role = next((r for r in COMPONENTS
                         if declared.casefold() == "http2." + r or
                         declared.casefold().startswith("http2." + r + ".")), None)
            expected_parent = Path(COMPONENTS[role]["source"]) if role else None
            if role is None or Path(rel).parent != expected_parent:
                c.fail(f"{rel} must be directly under {expected_parent or '<component>/src'}")
        if kind == "unit" and Path(rel).stem.casefold() != declared.casefold():
            c.fail(f"{rel} declares {kind} {declared}; file name does not match")
        key = declared.casefold() if kind == "unit" else f"program:{rel.casefold()}"
        if kind == "unit":
            if key in units:
                c.fail(f"unit {declared} duplicates {units[key][0]} in {units[key][1].relative_to(ROOT)}")
            else:
                units[key] = (declared, path)
        parsed[key] = (declared, path, kind, parse_pascal(path)[1])
    if not any(path.relative_to(ROOT).parts[0] in ("common", "client", "server", "tls") for _, path in units.values()):
        c.fail("component source directories have no production units; source dependency checks cannot pass")
    names = set(units)
    json_prefixes = ("fpjson", "json", "system.json")
    xml_prefixes = ("xml", "dom")
    interface_graph: dict[str, list[str]] = {}
    for key, (declared, source_path, kind, edges) in parsed.items():
        rel = source_path.relative_to(ROOT).as_posix()
        rel_parts = Path(rel).parts
        interface_graph[key] = []
        group = declared.casefold()
        for dep, section in edges:
            d = dep.casefold()
            if section == "interface" and d in names:
                interface_graph[key].append(d)
            if (d == "http2" or d.startswith("http2.")) and d not in names:
                c.fail(f"{rel} uses unknown project unit {dep}")
            role = "integration" if "integration" in rel_parts else next(
                (part for part in rel_parts if part in ("common", "client", "server")), None)
            if role == "common" and d.startswith(("http2.client", "http2.server")):
                c.fail(f"{rel} has common-to-role dependency on {dep}")
            if role == "client" and d.startswith("http2.server"):
                c.fail(f"{rel} has client-to-server dependency on {dep}")
            if role == "server" and d.startswith("http2.client"):
                c.fail(f"{rel} has server-to-client dependency on {dep}")
            source_unit = rel_parts[0] in ("common", "client", "server", "tls")
            test_file = rel_parts[0] == "test"
            readers_unit = group == "http2.client.readers" or group.startswith("http2.client.readers.")
            json_xml = d.startswith(json_prefixes + xml_prefixes)
            if source_unit and json_xml and not readers_unit:
                c.fail(f"{rel} has JSON/XML dependency outside the optional Readers group: {dep}")
            if test_file and role == "common" and json_xml:
                c.fail(f"{rel} has common-test dependency on JSON/XML unit {dep}")
            if test_file and role == "client" and json_xml and not readers_unit:
                c.fail(f"{rel} has client-test JSON/XML dependency outside Readers: {dep}")
            if test_file and role == "server" and json_xml:
                c.fail(f"{rel} has server-test dependency on JSON/XML unit {dep}")
            if group.startswith("http2.common"):
                if d.startswith(("http2.client", "http2.server", "mormot.", "fpjson", "jsonparser", "xml")):
                    c.fail(f"{rel} has prohibited {section} dependency on {dep}")
            if source_unit and group.startswith("http2.client") and d.startswith("http2.client.readers") and not readers_unit:
                c.fail(f"{rel} has optional Readers dependency from client core: {dep}")
            if source_unit and group.startswith("http2.client.") and not readers_unit and d == "http2.client":
                c.fail(f"client implementation unit {rel} imports its facade {dep}")
            if source_unit and group.startswith("http2.server.") and d == "http2.server":
                c.fail(f"server implementation unit {rel} imports its facade {dep}")
            if source_unit and group.startswith("http2.common.") and d == "http2.common":
                c.fail(f"common implementation unit {rel} imports its facade {dep}")
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(node: str, chain: list[str]) -> None:
        if node in visiting:
            cycle = chain[chain.index(node):] + [node] if node in chain else chain + [node]
            c.fail("interface dependency cycle: " + " -> ".join(parsed[n][0] for n in cycle))
            return
        if node in visited:
            return
        visiting.add(node)
        for child in interface_graph.get(node, []):
            visit(child, chain + [child])
        visiting.remove(node)
        visited.add(node)

    for node in interface_graph:
        visit(node, [node])
    production_units = sum(1 for _, path in units.values()
                           if path.relative_to(ROOT).parts[0] in ("common", "client", "server", "tls"))
    print(f"Checked {len(header_files)} Pascal headers/sizes, {len(files)} active files, "
          f"{production_units} production units, and {len(units)} total unit declarations")
    run_yaml(c)


def run_yaml(c: Checks) -> None:
    script = ROOT / "tools/check/yaml_headers.rb"
    if not script.exists():
        c.fail("tools/check/yaml_headers.rb is missing")
        return
    try:
        result = subprocess.run(["ruby", str(script)], cwd=ROOT, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except FileNotFoundError:
        c.fail("Ruby YAML parser is required for document and Pascal headers")
        return
    if result.returncode:
        for line in result.stdout.splitlines():
            c.fail(line)
    else:
        print(result.stdout.rstrip())


def docs_check(c: Checks) -> None:
    docs = sorted(p for p in (ROOT / "doc").rglob("*.md") if p.is_file())
    if not docs:
        c.fail("doc/ has no Markdown documents")
        return
    if not (ROOT / "doc/README.md").exists():
        c.fail("doc/README.md is missing; the document index is required")
    run_yaml(c)
    for path in docs:
        rel = path.relative_to(ROOT).as_posix()
        text = path.read_text(errors="replace")
        if re.search(r"\bplan/|\.ai/|\bstory\b", text, re.I):
            c.fail(f"{rel} refers to plan/, .ai/, or a story")
        if path.name != "README.md" or path.parent != ROOT / "doc/references":
            body = re.sub(r"\A---\n.*?\n---\n", "", text, count=1, flags=re.S)
            prose = re.sub(r"```.*?```", " ", body, flags=re.S)
            prose = re.sub(r"`[^`]*`", " code ", prose)
            imperative = re.search(
                r"(?i)(?:^|[.!?]\s+|\n)\s*(?:[-*+]\s+|\d+[.)]\s+)?(?:Add|Write|Use|Set|Call|Read|Make|Check|Keep|Put|Run|Build|Hold|Avoid|See|Take|Give|Move|Remove|Ensure|Replace|Change|Report|Fix|Do not)\s+[A-Za-z]",
                prose)
            if imperative:
                line = prose.count("\n", 0, imperative.start()) + 1
                c.fail(f"{rel}:{line} may use the imperative mood")
            if rel != "doc/README.md" and not (ROOT / "doc/README.md").exists():
                c.fail("doc/README.md is missing; the document index is required")
            elif rel != "doc/README.md" and (ROOT / "doc/README.md").exists():
                index = (ROOT / "doc/README.md").read_text(errors="replace")
                if rel.removeprefix("doc/") not in index:
                    c.fail(f"{rel} is not listed in doc/README.md")
            for match in re.finditer(r"\[[^\]]*\]\(([^)]+)\)", body):
                target = match.group(1).split("#", 1)[0].strip()
                if not target or target.startswith(("http://", "https://", "mailto:")):
                    continue
                target_path = (path.parent / target).resolve()
                if not target_path.exists():
                    c.fail(f"{rel} links to missing path {target}")
    print(f"Checked {len(docs)} documentation file(s)")


def packages_check(c: Checks) -> None:
    version_check(c)
    package_paths = package_files()
    group_path = ROOT / "http2components.lpg"
    if not group_path.is_file():
        c.fail("http2components.lpg is missing")
    else:
        try:
            group_tree = ET.parse(group_path)
            group_targets = [node.get("FileName", "")
                             for node in group_tree.findall("./ProjectGroup/Targets/Target")]
            resolved_targets = [(group_path.parent / name).resolve() for name in group_targets]
            expected_targets = {path.resolve() for path in package_paths}
            if len(resolved_targets) != len(set(resolved_targets)):
                c.fail("http2components.lpg lists a package more than once")
            if set(resolved_targets) != expected_targets:
                c.fail("http2components.lpg package targets do not match the available packages")
            for resolved in resolved_targets:
                if ROOT not in resolved.parents or not resolved.is_file():
                    c.fail(f"http2components.lpg names an invalid package target: {resolved}")
        except ET.ParseError as error:
            c.fail(f"http2components.lpg is invalid XML: {error}")
    packages = {p.name for p in package_paths}
    expected = {"http2common.lpk", "http2client.lpk", "http2server.lpk"}
    for missing in sorted(expected - packages):
        c.fail(f"required package {missing} is missing")
    sources = sorted(source for base in source_dirs() for source in base.rglob("*.pas"))
    if not sources:
        c.fail("component source directories have no production units; package inventory cannot pass")
    else:
        listed: dict[str, list[str]] = {}
        output_dirs: dict[str, str] = {}
        for package in package_paths:
            try:
                tree = ET.parse(package)
            except ET.ParseError as error:
                c.fail(f"{package.name} is invalid XML: {error}")
                continue
            for item in tree.iter("Filename"):
                name = item.get("Value", "")
                if not name.lower().endswith(".pas"):
                    continue
                source_path = (package.parent / name).resolve()
                if ROOT not in source_path.parents:
                    c.fail(f"{package.name} names a source outside the repository: {name}")
                elif not source_path.exists():
                    c.fail(f"{package.name} names missing source {name}")
                listed.setdefault(source_path.relative_to(ROOT).as_posix(), []).append(package.name)
            deps = {node.get("Value", "").casefold()
                    for node in tree.findall(".//RequiredPkgs/*/PackageName")}
            role_deps = deps & {"http2common", "http2client", "http2server", "http2clientreaders",
                                "http2openssl", "http2tlslib"}
            expected_deps = {
                "http2common.lpk": set(),
                "http2client.lpk": {"http2common"},
                "http2server.lpk": {"http2common"},
                "http2clientreaders.lpk": {"http2common", "http2client"},
                "http2openssl.lpk": {"http2common"},
                "http2tlslib.lpk": {"http2common"},
            }.get(package.name.casefold())
            if expected_deps is None or role_deps != expected_deps:
                c.fail(f"{package.name} has invalid component dependencies: {sorted(role_deps)}")
            license_node = tree.find(".//Package/License")
            if license_node is None or license_node.get("Value") != "Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)":
                c.fail(f"{package.name} does not declare the approved dual license")
            if package.name.casefold() == "http2common.lpk":
                search_node = tree.find(".//OtherUnitFiles")
                if search_node is not None and "mormot" in search_node.get("Value", "").casefold():
                    c.fail("http2common.lpk must not depend on mORMot2")
            unit_out = tree.find(".//UnitOutputDirectory")
            unit_out_value = unit_out.get("Value", "") if unit_out is not None else ""
            out_parts = Path(unit_out_value).parts
            resolved_out = (package.parent / unit_out_value).resolve()
            if (not unit_out_value or Path(unit_out_value).is_absolute()
                    or ROOT / "bin" not in resolved_out.parents):
                c.fail(f"{package.name} must write compiler units under bin/")
            folded_out = resolved_out.as_posix().casefold()
            if folded_out in output_dirs:
                c.fail(f"{package.name} shares compiler output with {output_dirs[folded_out]}")
            elif folded_out:
                output_dirs[folded_out] = package.name
            declared_count = tree.find(".//Files")
            entries = sum(1 for item in tree.iter("Filename"))
            if declared_count is not None:
                try:
                    expected_count = int(declared_count.get("Count", "-1"))
                except ValueError:
                    expected_count = -1
                if expected_count != entries:
                    c.fail(f"{package.name} lists {expected_count} files but has {entries} entries")
        for source in sources:
            rel = source.relative_to(ROOT).as_posix()
            owners = listed.get(rel, [])
            if len(owners) != 1:
                c.fail(f"{rel} is listed by {len(owners)} package files; expected one")
                continue
            stem = source.stem.casefold()
            if stem.startswith("http2.common"):
                expected = "http2common.lpk"
            elif stem.startswith("http2.client.readers"):
                expected = "http2clientreaders.lpk"
            elif stem.startswith("http2.client"):
                expected = "http2client.lpk"
            elif stem.startswith("http2.server"):
                expected = "http2server.lpk"
            elif stem.startswith("http2.openssl"):
                expected = "http2openssl.lpk"
            elif stem.startswith("http2.tlslib"):
                expected = "http2tlslib.lpk"
            else:
                expected = None
            if expected and owners[0].casefold() != expected:
                c.fail(f"{rel} belongs in {expected}, not {owners[0]}")
    print(f"Checked {len(packages)} package file(s) and {len(sources)} source file(s)")


def component_check(c: Checks, component: str) -> None:
    if component not in COMPONENTS:
        c.fail(f"unknown component {component}")
        return
    source_dir = ROOT / COMPONENTS[component]["source"]
    if not source_dir.is_dir():
        c.fail(f"required component source directory is missing: {COMPONENTS[component]['source']}")
        return
    sources = sorted(source_dir.rglob("*.pas"))
    if not sources:
        c.fail(f"component {component} has no Pascal source units")
    package_dir = ROOT / COMPONENTS[component]["package_dir"]
    packages = [package_dir / (name + ".lpk")
                for name in COMPONENTS[component]["packages"]]
    listed: dict[Path, int] = {}
    for package in packages:
        if not package.is_file():
            c.fail(f"required component package is missing: {package.relative_to(ROOT)}")
            continue
        try:
            tree = ET.parse(package)
        except ET.ParseError as error:
            c.fail(f"{package.relative_to(ROOT)} is invalid XML: {error}")
            continue
        for item in tree.iter("Filename"):
            name = item.get("Value", "")
            if name.lower().endswith(".pas"):
                listed[(package.parent / name).resolve()] = listed.get((package.parent / name).resolve(), 0) + 1
    for source in sources:
        if listed.get(source.resolve(), 0) != 1:
            c.fail(f"{source.relative_to(ROOT)} must be listed once in its component package")
        unit, _ = parse_pascal(source)
        if unit is None or unit.casefold() != source.stem.casefold():
            c.fail(f"{source.relative_to(ROOT)} has an invalid unit declaration")
        if len(source.read_text(errors="replace").splitlines()) >= 1000:
            c.fail(f"{source.relative_to(ROOT)} has 1000 or more lines")
    for source_path, count in listed.items():
        if source_path not in {source.resolve() for source in sources} or count != 1:
            c.fail(f"component package has an invalid or duplicate source: {source_path}")
    run_yaml(c)
    print(f"Checked component {component}: {len(sources)} source unit(s), {len(packages)} package(s)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("check", choices=("version", "source", "docs", "packages", "component"))
    parser.add_argument("--component", choices=tuple(COMPONENTS))
    args = parser.parse_args()
    c = Checks()
    if args.check == "component":
        if not args.component:
            parser.error("component check needs --component")
        component_check(c, args.component)
    else:
        {"version": version_check, "source": source_check,
         "docs": docs_check, "packages": packages_check}[args.check](c)
    return c.done()


if __name__ == "__main__":
    sys.exit(main())
