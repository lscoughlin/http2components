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
        suite, method = row[suite_key], row[method_key]
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
