#!/usr/bin/env python3
"""Check retained source tests against their exact merged methods."""
import csv
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


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
            if method == 'program-main':
                routine = re.search(r'(?is)\bbegin\b[\s\S]*\bend\.', source)
            else:
                routine = re.search(
                    r'(?im)^\s*(?:procedure|function)\s+' + re.escape(method) +
                    r'\b[\s\S]*?(?=^\s*(?:procedure|function)\s+|\Z)', source)
            if not routine:
                errors.append(f'{path}: missing program routine {method} for {origin}')
                continue
            if case == method:
                errors.append(f'{path}: program mapping needs an assertion marker for {origin}')
            elif not re.search(r"'" + re.escape(case) + r"'", routine.group()):
                errors.append(f'{path}: missing program assertion {case!r} in {method} for {origin}')
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
