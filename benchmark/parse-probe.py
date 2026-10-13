"""Build and run the bounded standalone F64 parse probe with pinned Habu."""
from pathlib import Path
import hashlib
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.build/parse-probe'
HABU = Path(os.environ.get('HABU_ROOT', str(Path.home() / '.local/lib/habu/c53b4d2c'))).resolve()
task_home = OUT / 'home'
for path in [task_home, OUT / 'cache', OUT / 'tmp']:
    path.mkdir(parents=True, exist_ok=True)
env = {**os.environ, 'HOME': str(task_home),
       'HABU_BUILD_CACHE': str(OUT / 'cache'), 'HB_TMP': str(OUT / 'tmp')}
source = ROOT / 'benchmark/parse-probe.f'
binary = OUT / 'probe'
build = subprocess.run(
    [str(HABU / 'bin/hb'), '--load', 'tools/hb-build.f', '--',
     str(source), '-o', str(binary)], cwd=HABU, env=env,
    stdin=subprocess.DEVNULL, capture_output=True, timeout=120)
(OUT / 'build.log').write_bytes(build.stdout + build.stderr)
if build.returncode:
    raise SystemExit(f'Build failed; see {OUT / "build.log"}')
run = subprocess.run([str(binary)], cwd=task_home, env=env,
                     stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
if run.returncode or run.stderr:
    raise SystemExit(f'Probe failed: exit={run.returncode}, stderr={run.stderr!r}')
elapsed, checksum = map(int, run.stdout.split())
expected = (241400 * 0x3ff4000000000000) % (1 << 64)
if expected >= 1 << 63:
    expected -= 1 << 64
result = dict(conversions=482800, elapsed_monotonic_ns=elapsed,
              checksum_i64=checksum, expected_checksum_i64=expected,
              source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
              binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
              note='Single diagnostic observation, not a controlled comparison.')
(OUT / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
if checksum != expected:
    raise SystemExit('Probe checksum mismatch')
