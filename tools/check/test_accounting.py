#!/usr/bin/env python3
"""Check retained source tests against their exact merged methods."""
import csv
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tools.check.repository import strip_pascal  # noqa: E402


def routine_source(source, method):
    """Select an implementation body, excluding interface declarations."""
    code = strip_pascal(source)
    if method == 'program-main':
        if not re.search(r'(?im)^\s*program\s+', code):
            return None
        blocks = list(re.finditer(r'\b(begin|end|case|try|record|object|class)\b',
                                  code, re.IGNORECASE))
        if not blocks or blocks[-1].group().lower() != 'end':
            return None
        depth = 1
        for block in reversed(blocks[:-1]):
            depth += 1 if block.group().lower() == 'end' else -1
            if depth == 0:
                return (source[block.start():blocks[-1].end()]
                        if block.group().lower() == 'begin' else None)
        return None
    implementation = re.search(r'\bimplementation\b', code, re.IGNORECASE)
    offset = implementation.end() if implementation else 0
    matches = list(re.finditer(
        r'(?im)^\s*(?:procedure|function)\s+' + re.escape(method) +
        r'\b[\s\S]*?(?=^\s*(?:procedure|function)\s+|\Z)', code[offset:]))
    for match in matches:
        if re.search(r'\bbegin\b', match.group(), re.IGNORECASE):
            return source[offset + match.start():offset + match.end()]
    return None


def check(path, count, unit_key, method_key, suite_key, removed_key=None):
    rows = list(csv.DictReader((ROOT / path).open(), delimiter='\t'))
    errors = []
    if len(rows) != count:
        errors.append(f'{path}: expected {count} source rows, found {len(rows)}')
    origins = set()
    for row in rows:
        origin = (row['source_suite'], row['source_test'])
        if origin in origins:
            errors.append(f'{path}: duplicate source test {origin}')
        origins.add(origin)
        if removed_key and row[removed_key] == 'removed-trivial-runner-sentinel':
            if origin != ('TTestProbe', 'TestSkeletonIsWired'):
                errors.append(f'{path}: unexpected removed source test {origin}')
            continue
        target = row[unit_key]
        file = ROOT / target
        if not target or not file.is_file():
            errors.append(f'{path}: missing target {target} for {origin}')
            continue
        suite = row[suite_key]
        method = row.get('target_method') or row[method_key]
        migration = row.get('migration_reason', '')
        case = row.get('target_case', '')
        disposition = row.get('disposition') or row.get('status', '')
        migration_statuses = {
            'migrated-neutral-alpn', 'migrated-neutral-build',
            'migrated-provider-program-case', 'migrated-neutral-method',
            'obsolete-provider-ownership', 'uncovered-behavior',
        }
        if disposition.startswith(('migrated-', 'obsolete-', 'uncovered-')) and disposition not in migration_statuses:
            errors.append(f'{path}: unknown migration disposition {disposition!r} for {origin}')
        if disposition in migration_statuses and not migration:
            errors.append(f'{path}: migration reason missing for {origin}')
        if disposition == 'uncovered-behavior' or migration.startswith('UNRESOLVED:'):
            errors.append(f'{path}: unresolved migration coverage for {origin}')
        if disposition in {
            'migrated-provider-program-case', 'obsolete-provider-ownership',
            'uncovered-behavior',
        } and (case or not suite):
            if suite or not method or not case:
                errors.append(f'{path}: invalid program case mapping for {origin}')
                continue
            source = file.read_text()
            routine = routine_source(source, method)
            if not routine:
                errors.append(f'{path}: missing program routine {method} for {origin}')
                continue
            markers = [marker for marker in case.split(';') if marker]
            if not markers or method in markers:
                errors.append(f'{path}: program mapping needs assertion markers for {origin}')
            for marker in markers:
                if not re.search(r"'" + re.escape(marker) + r"'", routine):
                    errors.append(f'{path}: missing program assertion {marker!r} in {method} for {origin}')
            continue
        # Standalone live programs have explicit program-level dispositions.
        if not suite and target.startswith('test/integration/'):
            continue
        pattern = r'(?im)^\s*(?:procedure|function)\s+' + re.escape(suite) + r'\s*\.\s*' + re.escape(method) + r'\s*[;(]'
        if not suite or not method or not re.search(pattern, file.read_text()):
            errors.append(f'{path}: missing {suite}.{method} in {target}')
    return errors


def main():
    errors = check('test/client/client-test-accounting.tsv', 913,
                   'target_unit', 'source_test', 'target_suite', 'disposition')
    errors += check('plan/notes/merge-0.30.0-M07-server-tests.tsv', 867,
                    'target_path', 'target_test', 'target_suite')
    for error in errors:
        print('FAIL', error)
    print(f'Checked 1780 source test records; failures={len(errors)}')
    return bool(errors)


if __name__ == '__main__':
    raise SystemExit(main())
