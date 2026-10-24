#!/usr/bin/env python3
# Architecture guard for the FRB-facing Rust surface.
#
# FRB 2.13 codegen collects types from every item under `rust_input = crate::api`
# (including private traits and pub(crate) helpers). If a dbpilot-core result type
# leaks into that module it becomes an auto-opaque type in frb_generated.rs without
# imports and the crate stops compiling. That is why the engine lives in
# src/query_engine.rs. This script fails CI when the invariant regresses.
#
# It also keeps the hand-written Dart kind constants in sync with query_types.rs.
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
api = root / 'rust' / 'src' / 'api'
problems = []


def code_lines(path):
    for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        if line.lstrip().startswith('//'):
            continue
        yield number, line


db_type = re.compile(r'\b(ColumnMeta|ResultSet|ResultBatch)\b')
for path in sorted(api.rglob('*.rs')):
    for number, line in code_lines(path):
        for match in db_type.finditer(line):
            name = match.group(1)
            if name == 'ResultSet' and 'ResultSetDto' in line:
                continue
            problems.append('%s:%d: %s leaked into rust/src/api' % (path.relative_to(root), number, name))

generated = root / 'rust' / 'src' / 'frb_generated.rs'
if generated.exists():
    text = generated.read_text(encoding='utf-8')
    if re.search(r'RustAutoOpaqueInner<(ColumnMeta|ResultSet|ResultBatch)>', text):
        problems.append('frb_generated.rs contains an opaque dbpilot-core type')

for path in sorted(api.rglob('*.rs')):
    for number, line in code_lines(path):
        if re.search(r'pub\(crate\)\s+(trait|struct)\s', line):
            problems.append('%s:%d: rust/src/api must stay a thin FRB surface'
                            % (path.relative_to(root), number))


def camel(name):
    return ''.join(part.capitalize() for part in name.split('_'))


rust_text = (root / 'rust' / 'src' / 'api' / 'query_types.rs').read_text(encoding='utf-8')
dart_text = (root / 'lib' / 'src' / 'api.dart').read_text(encoding='utf-8')
rust_consts = {}
for prefix, name, value in re.findall(r'(CELL|EVENT)_KIND_([A-Z_]+): u8 = ([0-9]+)', rust_text):
    key = ('cellKind' if prefix == 'CELL' else 'queryEvent') + camel(name)
    rust_consts[key] = int(value)
dart_consts = {name: int(value) for name, value in
               re.findall(r'const int (cellKind[A-Za-z]+|queryEvent[A-Za-z]+) = ([0-9]+);', dart_text)}
for key, value in sorted(rust_consts.items()):
    if key not in dart_consts:
        problems.append('Dart is missing kind constant ' + key)
    elif dart_consts[key] != value:
        problems.append('kind code mismatch for %s: rust=%d dart=%d' % (key, value, dart_consts[key]))
for key in sorted(set(dart_consts) - set(rust_consts)):
    problems.append('Dart defines a kind constant that Rust does not: ' + key)

# 5) MySQL row decoders: value_to_json (JSON path) and raw_cell (RawCell path)
#    duplicate the same type-dispatch table. They must stay in lock-step.
row_rs = root / 'rust' / 'src' / 'drivers' / 'mysql' / 'row.rs'
if row_rs.exists():
    row_text = row_rs.read_text(encoding='utf-8')

    def function_body(signature):
        start = row_text.index(signature)
        brace = row_text.index('{', start)
        depth = 0
        for index in range(brace, len(row_text)):
            char = row_text[index]
            if char == '{':
                depth += 1
            elif char == '}':
                depth -= 1
                if depth == 0:
                    return row_text[brace:index + 1]
        raise ValueError('unbalanced braces in ' + signature)

    try:
        value_body = function_body(
            'pub fn value_to_json(row: &MySqlRow, idx: usize) -> Value {')
        raw_body = function_body(
            'pub fn raw_cell(row: &MySqlRow, idx: usize) -> RawCell {')
    except ValueError:
        problems.append('could not locate value_to_json/raw_cell in mysql/row.rs')
    else:
        type_literal = re.compile(r'"([A-Z][A-Z0-9_]*)"')
        value_types = set(type_literal.findall(value_body))
        raw_types = set(type_literal.findall(raw_body))
        if value_types != raw_types:
            problems.append(
                'mysql/row.rs type tables drifted: value_to_json=%s raw_cell=%s'
                % (sorted(value_types - raw_types), sorted(raw_types - value_types)))
        if value_body.count('if ') != raw_body.count('if '):
            problems.append(
                'mysql/row.rs decoders drifted: if-branch count value_to_json=%d raw_cell=%d'
                % (value_body.count('if '), raw_body.count('if ')))
        if value_body.count('=>') != raw_body.count('=>'):
            problems.append(
                'mysql/row.rs decoders drifted: match-arm count value_to_json=%d raw_cell=%d'
                % (value_body.count('=>'), raw_body.count('=>')))
        if value_body.count('tname') != raw_body.count('tname'):
            problems.append(
                'mysql/row.rs decoders drifted: tname references value_to_json=%d raw_cell=%d'
                % (value_body.count('tname'), raw_body.count('tname')))

if problems:
    print('api-surface guard: FAILED', file=sys.stderr)
    for problem in problems:
        print('  - ' + problem, file=sys.stderr)
    sys.exit(1)
print('api-surface guard: OK')