"""Measure the pinned Zig reference's actual scheduling-dependent output on synthetic logs."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from test import event, write_rows  # noqa: E402


def main() -> None:
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / 'benchmark/bin/zzusage-zig-full-small').resolve()
    with tempfile.TemporaryDirectory(prefix='zzusage-order-') as td:
        root = Path(td)
        for i in range(24):
            write_rows(root, f'projects/p{i:02d}/f{i:02d}.jsonl', [
                event('2026-01-02T00:00:00Z', 'shared', f'model-{i:03}', inp=i + 1)])
        env = {**os.environ, 'HOME': str(root)}
        observations = {}
        for command, args in {'daily-text': ['daily'], 'sessions-json': ['sessions', '--json']}.items():
            hashes = set()
            projects = set()
            for _ in range(40):
                cp = subprocess.run([binary, *args, '--data-dir', str(root)],
                                    capture_output=True, check=True, timeout=60, env=env)
                hashes.add(hashlib.sha256(cp.stdout).hexdigest())
                if '--json' in args:
                    projects.add(json.loads(cp.stdout)['rows'][0]['project'])
            observations[command] = {'runs': 40, 'distinct_stdout': len(hashes),
                                     'distinct_projects': sorted(projects)}
    out = ROOT / '.build/test-results/parallel-order.json'
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(observations, indent=2) + '\n')
    print(json.dumps(observations, indent=2))


if __name__ == '__main__':
    main()
