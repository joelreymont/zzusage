"""Measure pinned binaries on bounded synthetic inputs; never scans the real HOME."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import tempfile
import threading
import time


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def event(session):
    return json.dumps(dict(timestamp='2026-01-02T03:04:05Z', sessionId=session,
                           model='claude-sonnet-4-5', input_tokens=1,
                           output_tokens=1, costUSD=0),
                      separators=(',', ':')).encode() + b'\n'


def priced_event(index):
    models = ('claude-sonnet-4-5', 'claude-opus-4-5', 'claude-3-5-haiku')
    return json.dumps(dict(timestamp=f'2026-01-{index % 28 + 1:02d}T03:04:{index % 60:02d}Z',
                           sessionId=f's{index:06d}', message=dict(
                               model=models[index % len(models)], usage=dict(
                                   input_tokens=1000 + index % 100, output_tokens=200,
                                   cache_creation_input_tokens=30,
                                   cache_read_input_tokens=40))),
                      separators=(',', ':')).encode() + b'\n'


def measure(binary, home, data, command, timeout):
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        start = time.perf_counter()
        proc = subprocess.Popen([str(binary), command, '--json', '--data-dir', str(data)],
                                cwd=home, env=dict(os.environ, HOME=str(home)),
                                stdin=subprocess.DEVNULL, stdout=out, stderr=err)
        timed_out = threading.Event()

        def terminate():
            try:
                os.kill(proc.pid, signal.SIGKILL)
                timed_out.set()
            except ProcessLookupError:
                pass

        timer = threading.Timer(timeout, terminate)
        timer.start()
        try:
            _, status, usage = os.wait4(proc.pid, 0)
            proc.returncode = os.waitstatus_to_exitcode(status)
        finally:
            timer.cancel()
            timer.join()
        wall = time.perf_counter() - start
        out.seek(0)
        err.seek(0)
        stdout = out.read()
        stderr = err.read()
        return dict(wall_s=wall, cpu_s=usage.ru_utime + usage.ru_stime,
                    peak_rss_bytes=usage.ru_maxrss * (1 if platform.system() == 'Darwin' else 1024),
                    exit=proc.returncode, timed_out=timed_out.is_set(),
                    stdout_bytes=len(stdout), stdout_sha256=hashlib.sha256(stdout).hexdigest(),
                    stderr=stderr.decode(errors='replace'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('zig', type=Path)
    parser.add_argument('habu', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, help='Prior Habu binary; runs the same five workloads')
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--timeout', type=float, default=20)
    parser.add_argument('--note', default='', help='Host load and coordination provenance')
    args = parser.parse_args()
    if args.repeats < 1 or args.timeout <= 0:
        parser.error('repeats and timeout must be positive')
    binaries = dict(zig=args.zig.resolve(), habu=args.habu.resolve())
    if args.baseline:
        binaries['baseline'] = args.baseline.resolve()
    report = dict(started_unix=time.time(), platform=platform.platform(), note=args.note,
                  max_seconds_per_child=args.timeout, binaries={
                      label: dict(path=str(path), bytes=path.stat().st_size, sha256=digest(path))
                      for label, path in binaries.items()}, cases=[])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='zzusage-perf-', dir=args.output.parent) as td:
        base = Path(td).resolve()
        home = base / 'home'
        home.mkdir()
        line = event('same-session')
        # Identical data and record count in the one-file and sixteen-file cases.
        per_file = (4 * 1024 * 1024 + len(line) - 1) // len(line)
        for name, files, count, command in [('one-file-64MiB', 1, per_file * 16, 'daily'),
                                           ('16-files-64MiB', 16, per_file * 16, 'daily'),
                                           ('20000-sessions', 1, 20000, 'sessions'),
                                           ('100000-sessions', 1, 100000, 'sessions'),
                                           ('100000-priced-sessions', 1, 100000, 'sessions')]:
            data = base / name
            paths = []
            for i in range(files):
                path = data / f'projects/p/file-{i}.jsonl'
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open('wb') as stream:
                    if command == 'daily':
                        stream.write(line * (count // files))
                    else:
                        for j in range(count):
                            stream.write(priced_event(j) if name == '100000-priced-sessions'
                                         else event(f's{j:06d}'))
                paths.append(path)
            before = [digest(path) for path in paths]
            runs = []
            labels = ['zig', 'habu']
            if args.baseline:
                labels.append('baseline')
            for repeat in range(args.repeats):
                for label in (labels if repeat % 2 == 0 else list(reversed(labels))):
                    run = dict(binary=label, repeat=repeat + 1,
                               **measure(binaries[label], home, data, command, args.timeout))
                    runs.append(run)
                    print(json.dumps(dict(case=name, **run)), flush=True)
            report['cases'].append(dict(case=name, command=command, records=count, files=files,
                                        bytes=sum(path.stat().st_size for path in paths), runs=runs,
                                        input_unchanged=before == [digest(path) for path in paths],
                                        exact_output_equal=len({(r['exit'], r['stdout_sha256'], r['stderr'])
                                                                for r in runs}) == 1))
        report['completed_unix'] = time.time()
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    return 0 if all(case['input_unchanged'] and case['exact_output_equal'] and
                    all(run['exit'] == 0 and not run['timed_out'] for run in case['runs'])
                    for case in report['cases']) else 1


if __name__ == '__main__':
    raise SystemExit(main())
