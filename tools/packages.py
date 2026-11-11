#!/usr/bin/env python3
"""Generate Lazarus manifests and Pascal package sources from component units."""
from pathlib import Path
import os
import argparse
import xml.etree.ElementTree as ET
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.components import ROOT, COMPONENTS, PACKAGE_COMPONENT

LICENSE = 'Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)'
HEADER = ('{**\n---\nlicense: ' + LICENSE +
          '\ncopyright: Copyright 2026 Liam Seamus Coughlin\n---\n}\n')
ACTIVE_PACKAGES = ('http2common', 'http2client', 'http2server', 'http2openssl',
                   'http2tlslib', 'http2clientreaders')
DEPENDENCY_LAYOUT = {
    'TlsLib4Pascal': 'TlsLib/src',
    'CryptoLib4Pascal': 'CryptoLib/src',
    'HashLib4Pascal': 'HashLib/src',
    'SimpleBaseLib4Pascal': 'SimpleBaseLib/src',
}


def dependency_source(name: str) -> tuple[Path, Path]:
    """Return the active source root and its portable repository-relative path."""
    override = os.environ.get(name.upper() + '_ROOT')
    actual_repo = Path(override) if override else ROOT / 'third_party' / name
    if not actual_repo.is_absolute():
        actual_repo = ROOT / actual_repo
    base = DEPENDENCY_LAYOUT[name]
    return actual_repo.resolve() / base, ROOT / 'third_party' / name / base


def dependency_directories(name: str, base: str, suffix: str) -> list[Path]:
    actual_root, manifest_root = dependency_source(name)
    search_root = actual_root.parent.parent / base
    manifest_search_root = manifest_root.parent.parent / base
    return sorted({manifest_search_root / path.parent.relative_to(search_root)
                   for path in search_root.rglob('*' + suffix)}) if search_root.exists() else []


def package_for(unit: str) -> str:
    if unit.startswith('Http2.Client.Readers'):
        return 'http2clientreaders'
    for role, package in (('Common', 'http2common'), ('Client', 'http2client'),
                          ('Server', 'http2server'), ('OpenSSL', 'http2openssl'),
                          ('TlsLib', 'http2tlslib')):
        if unit == 'Http2.' + role or unit.startswith('Http2.' + role + '.'):
            return package
    raise ValueError('Unknown package owner: ' + unit)


def render(name: str, sources: list[Path]) -> dict[Path, str]:
    component = PACKAGE_COMPONENT[name]
    package_dir = ROOT / COMPONENTS[component]["package_dir"]
    root = ET.Element('CONFIG')
    pkg = ET.SubElement(root, 'Package', Version='5')
    def value(parent, tag, text):
        return ET.SubElement(parent, tag, Value=text)
    value(pkg, 'PathDelim', '/')
    value(pkg, 'Name', name)
    value(pkg, 'Type', 'RunTimeOnly')
    value(pkg, 'Author', 'Liam Seamus Coughlin')
    value(pkg, 'Description', 'HTTP/2 ' + name.removeprefix('http2') + ' library for Free Pascal')
    ET.SubElement(pkg, 'Version', Major='0', Minor='30', Release='0', Build='0')
    value(pkg, 'License', LICENSE)
    opts = ET.SubElement(pkg, 'CompilerOptions')
    value(opts, 'Version', '11')
    if component == 'openssl':
        value(ET.SubElement(opts, 'Other'), 'CustomOptions', '-dUSE_OPENSSL')
    paths = ET.SubElement(opts, 'SearchPaths')
    def relative(path: Path) -> str:
        return Path(os.path.relpath(path, package_dir)).as_posix()
    include_roles = ('common',) if component == 'common' else ('common', component)
    include_paths = [ROOT / COMPONENTS[role]['source'] for role in include_roles]
    if component == 'tlslib':
        for dependency, base in DEPENDENCY_LAYOUT.items():
            include_paths.extend(dependency_directories(dependency, base, '.inc'))
    value(paths, 'IncludeFiles', ';'.join(relative(path) for path in include_paths))
    output = ROOT / 'bin' / '$(TargetCPU)-$(TargetOS)' / 'default' / ('package-' + name) / 'units'
    value(paths, 'UnitOutputDirectory', relative(output))
    search = [relative(ROOT / COMPONENTS['common']['source'])]
    if component == 'tlslib':
        search = [relative(ROOT / 'bin' / '$(TargetCPU)-$(TargetOS)' / 'default' /
                           'tlslib' / 'units' / 'bootstrap'),
                  *search, relative(ROOT / COMPONENTS[component]['source'])]
    elif component in ('client', 'server', 'openssl'):
        search.append(relative(ROOT / COMPONENTS[component]['source']))
    if component == 'client' and name == 'http2clientreaders':
        search.extend(relative(ROOT / 'third_party/mORMot2/src' / p) for p in ('core', 'lib'))
    elif component in ('client', 'server', 'openssl'):
        search.extend(relative(ROOT / 'third_party/mORMot2/src' / p) for p in ('core', 'lib', 'net', 'crypt'))
    elif component == 'tlslib':
        for dependency, base in DEPENDENCY_LAYOUT.items():
            search.extend(relative(path) for path in dependency_directories(dependency, base, '.pas'))
        # Package manifests are source-only metadata. tools/build.py supplies
        # the exact dependency paths for command-line builds.
    value(paths, 'OtherUnitFiles', ';'.join(search))
    syntax = ET.SubElement(ET.SubElement(opts, 'Parsing'), 'SyntaxOptions')
    value(syntax, 'SyntaxMode', 'Delphi')
    value(syntax, 'IncludeAssertionCode', 'True')
    files = ET.SubElement(pkg, 'Files', Count=str(len(sources)))
    for i, source in enumerate(sources, 1):
        item = ET.SubElement(files, 'Item' + str(i))
        value(item, 'Filename', source.relative_to(package_dir).as_posix())
        value(item, 'UnitName', source.stem)
    dependencies = ['FCL']
    if name != 'http2common':
        dependencies.append('http2common')
    if name == 'http2clientreaders':
        dependencies.append('http2client')
    requires = ET.SubElement(pkg, 'RequiredPkgs', Count=str(len(dependencies)))
    for i, dep in enumerate(dependencies, 1):
        item = ET.SubElement(requires, 'Item' + str(i))
        value(item, 'PackageName', dep)
    value(ET.SubElement(pkg, 'UsageOptions'), 'UnitPath', '$(PkgOutDir)')
    ET.indent(root, space='  ')
    xml = '<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(root, encoding='unicode') + '\n'
    pascal = HEADER + '// Generated by tools/packages.py from the source unit inventory.\n'
    pascal += 'unit ' + name + ';\n\n{$mode delphi}\n\ninterface\n\nuses\n'
    pascal += ',\n'.join('  ' + p.stem for p in sources) + ';\n\nimplementation\n\nend.\n'
    return {package_dir / (name + '.lpk'): xml, package_dir / (name + '.pas'): pascal}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    groups = {name: [] for name in ACTIVE_PACKAGES}
    required_dirs = [ROOT / COMPONENTS[name]['source'] for name in COMPONENTS]
    for source_dir in required_dirs:
        if not source_dir.is_dir():
            raise SystemExit('Required component source directory is missing: ' + source_dir.relative_to(ROOT).as_posix())
    for source_dir in required_dirs:
        for source in sorted(source_dir.rglob('*.pas')):
            package = package_for(source.stem)
            if package not in groups:
                raise SystemExit(f'No active package definition for {source.relative_to(ROOT)}')
            groups[package].append(source)
    stale = []
    for name, sources in groups.items():
        if not sources:
            raise SystemExit('No sources for package ' + name)
        for path, content in render(name, sources).items():
            if args.check:
                if not path.exists() or path.read_text() != content:
                    stale.append(path.relative_to(ROOT).as_posix())
            else:
                path.write_text(content)
    if stale:
        raise SystemExit('Package files need regeneration with tools/packages.py: ' + ', '.join(stale))
    print('Package inventory ' + ('matches' if args.check else 'generated') + ': ' +
          ', '.join(name + '=' + str(len(sources)) for name, sources in groups.items()))


if __name__ == '__main__':
    main()
