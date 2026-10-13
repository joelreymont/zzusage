"""Full CLI differential against the pinned Zig build, using synthetic JSONL only."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent


def event(ts='2026-01-02T12:34:56Z', session='one', model='claude-sonnet-4-5',
          inp=1000, out=200, create=30, read=40, cost=None):
    row = {'timestamp': ts, 'sessionId': session,
           'message': {'model': model, 'usage': {
               'input_tokens': inp, 'output_tokens': out,
               'cache_creation_input_tokens': create,
               'cache_read_input_tokens': read}}}
    if cost is not None:
        row['costUSD'] = cost
    return row


def write_rows(root: Path, relative: str, rows):
    target = root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(b'\n'.join(
        json.dumps(row, separators=(',', ':')).encode() if isinstance(row, dict)
        else row if isinstance(row, bytes) else row.encode()
        for row in rows) + b'\n')
    return target


def base_fixture(root: Path):
    a = root / 'one'
    b = root / 'two'
    write_rows(a, 'projects/-Users-joel-Work-alpha/first.jsonl', [
        event('2026-01-31T23:30:00Z', 'session-alpha', 'claude-sonnet-4-5-20250929', 1000000, 100000, 200000, 300000),
        event('2026-02-01T00:15:00Z', 'session-beta', 'claude-opus-4-5', 1500, 300, 15, 75),
    ])
    write_rows(a, 'projects/-Users-joel-Work-alpha/nested/second.jsonl', [
        event('2026-02-02T12:00:00Z', 'session-gamma', 'claude-3-5-haiku', 10, 20, cost=1.125),
    ])
    write_rows(b, 'projects/-private-tmp-beta/third.jsonl', [
        event('2025-12-31T23:45:00Z', 'session-delta', '<synthetic>', 2000000, 500, cost=4.25),
    ])
    write_rows(a, 'projects/-Users-joel-Work-alpha/ignored.txt', [event(inp=999999)])
    return [a, b]


def fixture(root: Path, kind: str):
    if kind.startswith('empty-session-'):
        d = root / 'one'
        row = event()
        row.pop('sessionId')
        if kind == 'empty-session-null':
            row['sessionId'] = None
        elif kind == 'empty-session-string':
            row['sessionId'] = ''
        rows = [row]
        if kind == 'empty-session-mixed':
            rows.append(event('2025-01-01T00:00:01Z', 'nonempty'))
        write_rows(d, 'projects/p/data.jsonl', rows)
        return [d]
    if kind == 'empty':
        a = root / 'one'
        (a / 'projects').mkdir(parents=True)
        return [a]
    if kind == 'home':
        write_rows(root, '.config/claude/projects/home-a/data.jsonl', [event(inp=11)])
        write_rows(root, '.claude/projects/home-b/data.jsonl', [event(inp=22)])
        return []
    if kind == 'home-empty':
        return []
    if kind == 'missing':
        return [root / 'missing']
    if kind == 'many-dirs':
        dirs = []
        for i in range(34):
            d = root / f'd{i}'
            write_rows(d, f'projects/p{i}/x.jsonl', [event(inp=i + 1)])
            dirs.append(d)
        return dirs
    if kind == 'many-rows':
        d = root / 'one'
        rows = [event(f'{1970 + i // 12:04d}-{i % 12 + 1:02d}-01T00:00:00Z', f's{i}', inp=i + 1)
                for i in range(525)]
        write_rows(d, 'projects/many/data.jsonl', rows)
        return [d]
    if kind == 'large-file':
        d = root / 'one'
        target = write_rows(d, 'projects/large/data.jsonl', [b'x' * (4 * 1024 * 1024 + 17), event(inp=17)])
        assert target.stat().st_size > 4 * 1024 * 1024
        return [d]
    if kind == 'long-fields':
        d = root / 'one'
        write_rows(d, 'projects/' + 'p' * 240 + '/data.jsonl', [
            event(session='s' * 270, model='m' * 270, inp=1)])
        return [d]
    if kind == 'deep':
        d = root / 'one'
        write_rows(d, 'projects/deep/' + '/'.join(f'd{i}' for i in range(35)) + '/data.jsonl', [event(inp=31)])
        return [d]
    if kind == 'hidden':
        d = root / 'one'
        for name, inp in [('.git', 1), ('.jj', 2), ('.jj-ws', 3), ('.dots', 4), ('.hidden', 5)]:
            write_rows(d, f'projects/p/{name}/data.jsonl', [event(inp=inp)])
        return [d]
    if kind == 'symlink':
        d = root / 'one'
        outside = root / 'outside'
        write_rows(d, 'projects/real/data.jsonl', [event(inp=4)])
        write_rows(outside, 'projects/outer/data.jsonl', [event(inp=9)])
        (d / 'projects' / 'linked-dir').symlink_to(outside / 'projects' / 'outer', target_is_directory=True)
        (d / 'projects' / 'linked-file.jsonl').symlink_to(d / 'projects' / 'real' / 'data.jsonl')
        return [d]
    if kind == 'threaded':
        d = root / 'one'
        for i in range(12):
            write_rows(d, f'projects/p{i}/data.jsonl', [
                event(f'2026-01-{i + 1:02d}T01:00:00Z', f'unique-{i}', inp=i + 1)])
        return [d]
    if kind == 'malformed':
        d = root / 'one'
        write_rows(d, 'projects/raw/data.jsonl', [
            b'{' + b'"timestamp":"2026-02-01T01:02:03Z","sessionId":"plain","input_tokens":21,"model":"claude-2"}',
            b'{' + b'"input_tokens":77,"timestamp":"2026-02-02T01:02:03Z","sessionId":"raw\\"quote","model":"claude-2"}',
            b'{' + b'"timestamp":"2026-02-03T01:02:03Z","input_tokens":1,"input_tokens":5,"costUSD":-1.125}',
            b'not-json "timestamp":"2026-02-04T00:00:00Z" "input_tokens":9',
        ])
        return [d]
    if kind == 'unsigned':
        d = root / 'one'
        write_rows(d, 'projects/u/data.jsonl', [
            event(inp=9223372036854775808, out=0, create=0, read=0, model='unknown')])
        return [d]
    if kind == 'unsigned-priced':
        d = root / 'one'
        write_rows(d, 'projects/u/data.jsonl', [
            event(inp=9223372036854775808, out=1, create=0, read=0, model='claude-sonnet-4-5')])
        return [d]
    if kind == 'deep-nesting':
        d = root / 'one'
        core = b'"timestamp":"2026-01-02T00:00:00Z","input_tokens":19,"model":"claude-2"'
        write_rows(d, 'projects/nest/data.jsonl', [b'{"z":' * 90 + b'{' + core + b'}' + b'}' * 90])
        return [d]
    if kind == 'wide-output':
        d = root / 'one'
        write_rows(d, 'projects/wide/data.jsonl', [
            event(session=f'w{i}', model=f'custom-model-{i:04d}', inp=i + 1) for i in range(600)])
        return [d]
    if kind == 'invalid-dates':
        d = root / 'one'
        write_rows(d, 'projects/date/data.jsonl', [
            event('2026-01-00T00:00:00Z', 'day-zero', inp=1),
            event('2026-13-01T00:00:00Z', 'month-thirteen', inp=2),
            event('2026x02x03x99x00x00Z', 'odd-separators', inp=3),
            event('1960-12-31T00:00:00Z', 'pre-epoch-year', inp=4),
        ])
        return [d]
    if kind == 'invalid-numeric-dates':
        d = root / 'one'
        write_rows(d, 'projects/date/data.jsonl', [
            event('202x-01-02T12:34:56Z', inp=1),
            event('2026-xx-02T12:34:56Z', inp=2),
            event('2026-01-02Txx:34:56Z', inp=3),
            event('2026-01-02T12:xx:56Z', inp=4),
            event('2026-01-02T12:34:xxZ', inp=5)])
        return [d]
    if kind == 'calendar-overflow':
        d = root / 'one'
        write_rows(d, 'projects/date/data.jsonl', [
            event('9999-12-99T00:00:00Z', inp=9)])
        return [d]
    if kind == 'signed-dates':
        d = root / 'one'
        write_rows(d, 'projects/date/data.jsonl', [
            event('2026-01-+2T00:00:00Z', inp=1),
            event('2026-01-02T+1:00:00Z', inp=2),
            event('2026-01-02T-0:00:00Z', inp=3),
            event('2_00-02-02T01:00:00Z', inp=4),
            event('2026-01-02T1_:00:00Z', inp=5),
            event('2026-01-02T-1:00:00Z', inp=6)])
        return [d]
    if kind.startswith('session-ties-'):
        d = root / 'one'
        count = int(kind.rsplit('-', 1)[-1])
        write_rows(d, 'projects/ties/data.jsonl', [
            event('2026-01-02T12:34:56Z', session=f's{i}', model='unknown',
                  inp=1, out=0, create=0, read=0) for i in range(count)])
        return [d]
    if kind == 'session-mixed-ties':
        d = root / 'one'
        write_rows(d, 'projects/ties/data.jsonl', [
            event(f'2026-01-02T12:34:{(i * 7) % 5:02d}Z', session=f's{i}',
                  model='unknown', inp=1, out=0, create=0, read=0)
            for i in range(40)])
        return [d]
    if kind == 'epoch-edge':
        d = root / 'one'
        write_rows(d, 'projects/date/data.jsonl', [
            event('1970-01-01T00:30:00Z', inp=7)])
        return [d]
    if kind == 'negative-status':
        d = root / 'one'
        write_rows(d, 'projects/date/data.jsonl', [
            event('1970-01-00T12:00:00Z', inp=8)])
        return [d]
    if kind == 'duplicate-cost-null':
        d = root / 'one'
        write_rows(d, 'projects/cost/data.jsonl', [
            b'{"timestamp":"2026-01-02T12:34:56Z","input_tokens":1000000,'
            b'"model":"claude-sonnet-4-5","sessionId":"s","costUSD":7,"costUSD":null}'])
        return [d]
    if kind == 'stacked-prefix':
        d = root / 'one'
        write_rows(d, 'projects/p/data.jsonl', [
            event(model='anthropic/openrouter/openai/claude-sonnet-4-5', inp=1000000,
                  out=0, create=0, read=0)])
        return [d]
    if kind == 'equal-sessions':
        d = root / 'one'
        write_rows(d, 'projects/p/data.jsonl', [event(session=s, inp=1000000)
                                                  for s in ('a', 'b', 'c')])
        return [d]
    if kind == 'project-users-short':
        d = root / 'one'
        write_rows(d, 'projects/-Users-joel/data.jsonl', [event()])
        return [d]
    if kind == 'project-private-tail':
        d = root / 'one'
        write_rows(d, 'projects/-private-tmp-/data.jsonl', [event()])
        return [d]
    if kind == 'binary-rounding':
        d = root / 'one'
        write_rows(d, 'projects/p/data.jsonl', [
            event(inp=10000000000049999999, out=0, create=0, read=0,
                  cost=0.49999999999999994)])
        return [d]
    if kind == 'wide-ansi-cost':
        d = root / 'one'
        write_rows(d, 'projects/p/data.jsonl', [event(cost=-1e24)])
        return [d]
    if kind == 'wide-status-cost':
        d = root / 'one'
        write_rows(d, 'projects/p/data.jsonl', [event(cost=-1e20)])
        return [d]
    if kind == 'rounding':
        d = root / 'one'
        write_rows(d, 'projects/cost/data.jsonl', [
            event(f'2026-03-{i+1:02d}T00:00:00Z', f'cost-{i}', cost=c)
            for i, c in enumerate([1.125, -1.125, 2.675, -2.675, 999.5, 1000.5])])
        return [d]
    if kind == 'carry-rounding':
        d = root / 'one'
        write_rows(d, 'projects/cost/data.jsonl', [
            event(f'2026-04-{i+1:02d}T00:00:00Z', f'carry-{i}', cost=c)
            for i, c in enumerate([9.995, 99.995, 999999.995, -9.995, -999999.995])])
        return [d]
    if kind == 'large-cost':
        d = root / 'one'
        rows = []
        for i, cost in enumerate([b'1e23', b'1e30', b'1e308', b'1e309', b'-1e309']):
            raw = json.dumps(event(f'2026-05-{i+1:02d}T00:00:00Z', f'large-{i}'),
                             separators=(',', ':')).encode()
            rows.append(raw[:-1] + b',"costUSD":' + cost + b'}')
        write_rows(d, 'projects/cost/data.jsonl', rows)
        return [d]
    if kind == 'price':
        d = root / 'one'
        models = ['claude-opus-4-5', 'claude-sonnet-4-5', 'claude-haiku-4-5',
                  'claude-opus-4-1', 'claude-opus-4', 'claude-sonnet-4',
                  'claude-3-5-sonnet', 'claude-3-5-haiku', 'claude-3-opus',
                  'claude-3-sonnet', 'claude-3-haiku', 'claude-2',
                  'anthropic/claude-sonnet-4-5', 'openrouter/claude-opus-4-5',
                  'openai/claude-haiku-4-5', 'unknown', '<synthetic>', '']
        write_rows(d, 'projects/prices/data.jsonl', [
            event(session=f'price-{i}', model=m, inp=1000000, out=100000, create=200000, read=300000)
            for i, m in enumerate(models)])
        return [d]
    if kind == 'many-models':
        d = root / 'one'
        write_rows(d, 'projects/models/data.jsonl', [
            event(session=f'm{i}', model=f'custom-model-{i}', inp=i + 1) for i in range(15)])
        return [d]
    if kind.startswith('growth-rows-'):
        count = int(kind.rsplit('-', 1)[1])
        d = root / 'one'
        rows = [event('2026-01-02T00:00:00Z', session=f's{i}', model='m',
                      inp=1, out=0, create=0, read=0) for i in range(count)]
        write_rows(d, 'projects/p/data.jsonl', rows + [rows[0]])
        return [d]
    if kind.startswith('growth-models-'):
        count = int(kind.rsplit('-', 1)[1])
        d = root / 'one'
        rows = [event('2026-01-02T00:00:00Z', session='s', model=f'm{i}',
                      inp=1, out=0, create=0, read=0) for i in range(count)]
        write_rows(d, 'projects/p/data.jsonl', rows + [rows[0]])
        return [d]
    if kind == 'growth-projects-6':
        dirs = []
        for name in 'abcdef':
            d = root / name
            write_rows(d, f'projects/{name}/data.jsonl', [
                event('2026-01-02T00:00:00Z', session='s', model='m',
                      inp=1, out=0, create=0, read=0)])
            dirs.append(d)
        return dirs + [dirs[0]]
    if kind == 'duplicate':
        dirs = base_fixture(root)
        return [dirs[0], dirs[0]]
    if kind == 'no-lf':
        dirs = base_fixture(root)
        target = dirs[0] / 'projects/no-lf/data.jsonl'
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(event(inp=37)))
        return dirs
    return base_fixture(root)


CASES = []
for command in ['', 'daily', 'weekly', 'blocks', 'monthly', 'sessions', 'statusline']:
    for json_flag in (False, True):
        CASES.append((f'{command or "default"}-{ "json" if json_flag else "text"}',
                      'base', ([command] if command else []) + (['--json'] if json_flag else [])))
for name, kind, args in [
    ('help', 'empty', ['--help']), ('help-command', 'empty', ['help']),
    ('help-overridden', 'empty', ['help', 'daily']),
    ('unknown-flags', 'base', ['nonsense', '--what', '--json']),
    ('order-ignored', 'base', ['daily', '--order', 'asc']),
    ('order-consumes', 'base', ['daily', '--order', 'monthly']),
    ('missing-order-value', 'empty', ['--order']),
    ('missing-data-dir-value', 'empty', ['--data-dir']),
    ('missing-timezone-value', 'empty', ['--timezone']),
    ('bad-timezone', 'base', ['daily', '--timezone', 'bad', '--json']),
    ('timezone-plus', 'base', ['daily', '--timezone', '+02:00', '--json']),
    ('timezone-minus', 'base', ['statusline', '--timezone', '-05:30']),
    ('compact-breakdown', 'base', ['--compact', '--breakdown']),
    ('home-json', 'home', ['--json']), ('home-text', 'home', []),
    ('home-empty-json', 'home-empty', ['--json']), ('home-empty-text', 'home-empty', []),
    ('missing-root', 'missing', ['--json']),
    ('empty-daily-json', 'empty', ['--json']), ('empty-daily-text', 'empty', []),
    ('empty-sessions-json', 'empty', ['sessions', '--json']),
    ('empty-sessions-text', 'empty', ['sessions']),
    ('empty-status-json', 'empty', ['statusline', '--json']),
    ('empty-status-text', 'empty', ['statusline']),
    ('duplicate-dir', 'duplicate', ['--json']),
    ('no-final-lf', 'no-lf', ['--json']),
    ('pricing-json', 'price', ['--json']), ('pricing-text', 'price', []),
    ('rounding-json', 'rounding', ['--json']), ('rounding-text', 'rounding', []),
    ('carry-rounding-json', 'carry-rounding', ['--json']),
    ('carry-rounding-text', 'carry-rounding', []),
    ('large-cost-json', 'large-cost', ['--json']),
    ('large-cost-text', 'large-cost', []),
    ('many-models-text', 'many-models', []),
    ('many-dirs', 'many-dirs', ['--json']),
    ('many-rows', 'many-rows', ['--json']),
    ('growth-rows-6', 'growth-rows-6', ['sessions', '--json']),
    ('growth-rows-25', 'growth-rows-25', ['sessions', '--json']),
    ('growth-models-6', 'growth-models-6', []),
    ('growth-models-25', 'growth-models-25', []),
    ('growth-projects-6', 'growth-projects-6', []),
    ('large-file', 'large-file', ['--json']),
    ('long-fields-json', 'long-fields', ['sessions', '--json']),
    ('long-fields-text', 'long-fields', ['sessions']),
    ('deep-dir', 'deep', ['--json']), ('hidden-dir', 'hidden', ['--json']),
    ('symlinks', 'symlink', ['--json']),
    ('threaded-json', 'threaded', ['--json']), ('threaded-text', 'threaded', []),
    ('malformed-json-bytes', 'malformed', ['sessions', '--json']),
    ('unsigned-counter', 'unsigned', ['--json']),
    ('unsigned-text', 'unsigned', []),
    ('unsigned-priced-json', 'unsigned-priced', ['--json']),
    ('unsigned-priced-text', 'unsigned-priced', []),
    ('deep-nesting', 'deep-nesting', ['--json']),
    ('wide-output-text', 'wide-output', []),
    ('invalid-dates-json', 'invalid-dates', ['--json']),
    ('invalid-dates-text', 'invalid-dates', []),
    ('invalid-numeric-dates', 'invalid-numeric-dates', ['--json']),
    ('calendar-overflow', 'calendar-overflow', ['--json']),
    ('calendar-overflow-monthly', 'calendar-overflow', ['monthly', '--json']),
    ('signed-dates-daily', 'signed-dates', ['--json']),
    ('signed-dates-sessions', 'signed-dates', ['sessions', '--json']),
    ('session-ties-26', 'session-ties-26', ['sessions', '--json']),
    ('session-ties-50', 'session-ties-50', ['sessions', '--json']),
    ('session-ties-100', 'session-ties-100', ['sessions', '--json']),
    ('session-mixed-ties', 'session-mixed-ties', ['sessions', '--json']),
    ('epoch-negative-day', 'epoch-edge', ['--json', '--timezone', '-01:00']),
    ('negative-only-status', 'negative-status', ['statusline', '--json']),
    ('duplicate-cost-null', 'duplicate-cost-null', ['--json']),
    ('stacked-prefix', 'stacked-prefix', ['--json']),
    ('equal-session-ties', 'equal-sessions', ['sessions', '--json']),
    ('project-users-short', 'project-users-short', []),
    ('project-private-tail', 'project-private-tail', []),
    ('binary-rounding', 'binary-rounding', []),
    ('wide-ansi-cost', 'wide-ansi-cost', []),
    ('wide-status-cost', 'wide-status-cost', ['statusline']),
]:
    CASES.append((name, kind, args))


def snapshot(root: Path):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


for empty_kind in ('missing', 'null', 'string', 'mixed'):
    for output in ([], ['--json']):
        CASES.append((f'empty-session-{empty_kind}-' + ('json' if output else 'text'),
                      f'empty-session-{empty_kind}', ['sessions', *output]))


def limit_fds():
    resource.setrlimit(resource.RLIMIT_NOFILE, (24, 24))


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: python3 test.py FULL_ZIG_BINARY HABU_BINARY')
    binaries = [str(Path(s).resolve()) for s in sys.argv[1:]]
    results = []
    external_output = os.environ.get('ZZUSAGE_TEST_OUTPUT_DIR')
    output_dir = Path(external_output).resolve() if external_output else ROOT / '.build/test-results'
    output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='zzusage-full-', dir=output_dir) as td:
        suite = Path(td)
        for name, kind, args in CASES:
            root = suite / name
            root.mkdir()
            dirs = fixture(root, kind)
            argv = args + [piece for d in dirs for piece in ('--data-dir', str(d))]
            before = snapshot(root)
            outputs = []
            for binary in binaries:
                cp = subprocess.run([binary, *argv], cwd=root, capture_output=True, timeout=60,
                                    env={**os.environ, 'HOME': str(root)})
                outputs.append((cp.returncode, cp.stdout, cp.stderr))
            unchanged = snapshot(root) == before
            passed = outputs[0] == outputs[1] and unchanged
            diffs = []
            for label, x, y in zip(('exit', 'stdout', 'stderr'), outputs[0], outputs[1]):
                if x != y:
                    diffs.append(label)
            if not unchanged:
                diffs.append('input-mutated')
            results.append({'name': name, 'kind': kind, 'args': args, 'passed': passed,
                            'different': diffs,
                            'zig': {'exit': outputs[0][0], 'stdout': outputs[0][1].decode(errors='replace'),
                                    'stderr': outputs[0][2].decode(errors='replace')},
                            'habu': {'exit': outputs[1][0], 'stdout': outputs[1][1].decode(errors='replace'),
                                     'stderr': outputs[1][2].decode(errors='replace')}})
            print(('PASS ' if passed else 'FAIL ') + name + ('' if passed else ' (' + ', '.join(diffs) + ')'), flush=True)

        root = suite / 'walk-fd-cleanup'
        root.mkdir()
        dirs = []
        blocked = []
        for i in range(12):
            d = root / str(i)
            denied = d / 'projects/a/b/denied'
            denied.mkdir(parents=True)
            blocked.append((denied, denied.stat().st_mode & 0o777))
            dirs.append(d)
        good = root / 'good'
        write_rows(good, 'projects/p/data.jsonl', [event(inp=1, out=0, create=0, read=0)])
        dirs.append(good)
        argv = ['--json', *(piece for d in dirs for piece in ('--data-dir', str(d)))]
        outputs = []
        try:
            for denied, _ in blocked:
                denied.chmod(0)
            for binary in binaries:
                cp = subprocess.run([binary, *argv], cwd=root, capture_output=True, timeout=60,
                                    env={**os.environ, 'HOME': str(root)}, preexec_fn=limit_fds)
                outputs.append((cp.returncode, cp.stdout, cp.stderr))
        finally:
            for denied, mode in blocked:
                denied.chmod(mode)
        try:
            report = json.loads(outputs[0][1])
            retained = any(row['input_tokens'] == 1 for row in report['rows'])
        except (ValueError, KeyError, TypeError):
            retained = False
        passed = outputs[0] == outputs[1] and outputs[0][0] == 0 and retained
        results.append({'name': 'walk-fd-cleanup', 'passed': passed,
                        'retained': retained, 'exit': [x[0] for x in outputs],
                        'stdout_equal': outputs[0][1] == outputs[1][1],
                        'stderr_equal': outputs[0][2] == outputs[1][2]})
        print(('PASS ' if passed else 'FAIL ') + 'walk-fd-cleanup', flush=True)

        for name, args, closed in [
            ('long-home-help', ['--help'], False),
            ('long-home-empty-json', ['--json'], False),
            ('closed-stdout-help', ['--help'], True),
            ('closed-stdout-json', ['--json'], True),
        ]:
            root = suite / name
            root.mkdir()
            env = {**os.environ, 'HOME': str(root) if closed else '/' + 'x' * 1500}
            outputs = []
            for binary in binaries:
                command = (['sh', '-c', 'exec 1>&-; exec "$@"', 'sh', binary, *args]
                           if closed else [binary, *args])
                cp = subprocess.run(command, cwd=root, capture_output=True, timeout=60, env=env)
                outputs.append((cp.returncode, cp.stdout, cp.stderr))
            passed = outputs[0] == outputs[1]
            results.append({'name': name, 'passed': passed,
                            'zig': {'exit': outputs[0][0], 'stdout': outputs[0][1].decode(errors='replace'),
                                    'stderr': outputs[0][2].decode(errors='replace')},
                            'habu': {'exit': outputs[1][0], 'stdout': outputs[1][1].decode(errors='replace'),
                                     'stderr': outputs[1][2].decode(errors='replace')}})
            print(('PASS ' if passed else 'FAIL ') + name, flush=True)

        # A sparse log can gain bytes between discovery and EOF. The append count is
        # intentionally nondeterministic; both programs must retain the first row.
        growing = []
        initial_tokens = 999999
        for label, binary in zip(('zig', 'habu'), binaries):
            root = suite / f'growing-log-{label}'
            root.mkdir()
            d = root / 'one'
            target = d / 'projects/p/data.jsonl'
            target.parent.mkdir(parents=True)
            with target.open('wb') as f:
                f.write(json.dumps(event(inp=initial_tokens, out=0, create=0, read=0))
                        .encode() + b'\n')
                f.seek(64 * 1024 * 1024)
                f.write(b'\n')
            appended = json.dumps(event(inp=1, out=0, create=0, read=0)).encode() + b'\n'
            stop = threading.Event()
            started = threading.Event()
            def append_loop():
                with target.open('ab', buffering=0) as f:
                    while not stop.is_set():
                        f.write(appended)
                        started.set()
                        time.sleep(0.0002)
            thread = threading.Thread(target=append_loop)
            thread.start()
            started.wait(timeout=5)
            try:
                cp = subprocess.run([binary, '--json', '--data-dir', str(d)], cwd=root,
                                    capture_output=True, timeout=60,
                                    env={**os.environ, 'HOME': str(root)})
            finally:
                stop.set()
                thread.join()
            try:
                report = json.loads(cp.stdout)
                kept = cp.returncode == 0 and cp.stderr == b'' and any(
                    row['input_tokens'] >= initial_tokens for row in report['rows'])
            except (ValueError, KeyError, TypeError):
                kept = False
            growing.append({'binary': label, 'passed': kept, 'exit': cp.returncode,
                            'stdout_prefix': cp.stdout[:240].decode(errors='replace'),
                            'stderr': cp.stderr.decode(errors='replace')})
        passed = all(x['passed'] for x in growing)
        results.append({'name': 'growing-sparse-log', 'passed': passed, 'runs': growing})
        print(('PASS ' if passed else 'FAIL ') + 'growing-sparse-log', flush=True)
        for size, name, retained in [
            (512 * 1024 * 1024 - 1, 'file-cap-minus-one', True),
            (512 * 1024 * 1024, 'file-cap-exact', True),
            (512 * 1024 * 1024 + 1, 'file-cap-plus-one', False),
        ]:
            root = suite / name
            root.mkdir()
            d = root / 'one'
            target = write_rows(d, 'projects/p/data.jsonl', [
                event(inp=33, out=0, create=0, read=0)])
            with target.open('r+b') as f:
                f.truncate(size)
            stat_before = target.stat()
            outputs = []
            kept = []
            for binary in binaries:
                cp = subprocess.run([binary, '--json', '--data-dir', str(d)], cwd=root,
                                    capture_output=True, timeout=120,
                                    env={**os.environ, 'HOME': str(root)})
                outputs.append((cp.returncode, cp.stdout, cp.stderr))
                try:
                    report = json.loads(cp.stdout)
                    kept.append(any(row['input_tokens'] == 33 for row in report['rows']))
                except (ValueError, KeyError, TypeError):
                    kept.append(None)
            stat_after = target.stat()
            passed = (outputs[0] == outputs[1] and kept == [retained, retained]
                      and stat_before.st_size == stat_after.st_size
                      and stat_before.st_mtime_ns == stat_after.st_mtime_ns)
            results.append({'name': name, 'passed': passed, 'bytes': size,
                            'retained': kept, 'exit': [x[0] for x in outputs],
                            'stdout_equal': outputs[0][1] == outputs[1][1],
                            'stderr_equal': outputs[0][2] == outputs[1][2]})
            print(('PASS ' if passed else 'FAIL ') + name, flush=True)
    report = {'binaries': binaries, 'passed': sum(r['passed'] for r in results),
              'total': len(results), 'cases': results}
    mode = Path(binaries[0]).name.rsplit('-', 1)[-1]
    out = output_dir / f'full-suite-{mode}.json'
    out.write_text(json.dumps(report, indent=2) + '\n')
    print(f"{report['passed']}/{report['total']} passed; {out}")
    return 0 if report['passed'] == report['total'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
