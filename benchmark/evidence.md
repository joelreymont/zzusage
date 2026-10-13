# Current audit and repair evidence

The independent [adversarial audit](audit.md) found failures missed by the
original 100-case suite. The repaired code was freshly built with pinned Habu
`c53b4d2c` and Zig 0.17.0 on macOS arm64. The full synthetic suite passed
**136/136 against each Zig size configuration**, including exact exit/stdout/
stderr comparisons and one nondeterministic append-retention check:
[small](results/adversarial/full-suite-small.json),
[smallest](results/adversarial/full-suite-smallest.json).
Verbose stdout is omitted in these saved summaries; `test.py` generates it
in ignored `.build/test-results/`. Input integrity is checked by the runner.
The [independent repair review](results/adversarial/review.json) found no
actionable findings in the reviewed repairs, including the output buffer,
bounded cent formatter, and stdout/stderr failure matrix.

## Binary size

| Executable | Bytes | SHA-256 |
|---|---:|---|
| Habu AOT | 115,836 | `f2f40102651c0a02e9243b19729ce54b6679c4e6f45c53f5b7da068334b5ec1b` |
| Zig stripped small | 277,912 | `1a74d7c7598a63be80bda00fa7d604fa13e1ebac41dec419c934080225acbb4b` |
| Zig smallest | 236,480 | `e0368efb53c045b5abc895f60376bdf0dafd1536c560a39243e2eca1972d58ec` |

The Habu executable remains **115,836 bytes**, 51.0% smaller than the smallest
measured Zig build. Its application code grew from 78,092 to 82,964 bytes and
carried data from 2,984 to 3,295 bytes; Mach-O padding absorbed the growth.
See [size breakdown](results/adversarial/habu-build.txt) and
[source/binary hashes](results/adversarial/builds.json). Size alone says
nothing about runtime speed or peak memory.

## Runtime and peak memory

The [runner](performance.py) used sequential existing binaries, three
alternating repetitions per workload, `perf_counter` wall time and `wait4`
per-child peak RSS. Each process had synthetic HOME and an explicit bounded
input root. Every exit, stdout hash and stderr matched; input hashes stayed
unchanged. The one-file and 16-file tests used **identical data**: 482,800
records totaling 67,109,200 bytes. Those scans and the two unpriced session
cases use explicit zero costs. The priced case has 100,000 distinct sessions,
nested usage fields, three model families, cache tokens, and varied timestamps
(21,000,001 input bytes).

| Workload | Zig median seconds | Habu median seconds | Zig median MiB RSS | Habu median MiB RSS |
|---|---:|---:|---:|---:|
| one-file-64MiB | 0.402 | 3.567 | 254.64 | 129.72 |
| 16-files-64MiB | 0.262 | 3.731 | 169.34 | 9.72 |
| 20000-sessions | 0.027 | 0.221 | 23.80 | 9.52 |
| 100000-sessions | 0.127 | 1.228 | 100.62 | 39.11 |
| 100000-priced-sessions | 0.252 | 0.889 | 127.34 | 46.22 |

The priced workload also ran the indexed application checkpoint `55e3a1cd`
on **the same input in the same batch**. Its median was 16.269 seconds and
46.36 MiB RSS: output buffering and bounded cent formatting therefore made
this report **18.31× faster**, with identical output. CPU samples and inclusive
phase timers identified both application causes; see [profiling](profile.md).
The earlier scaling-only measurements remain available as
[checkpoint evidence](results/adversarial/performance-scaling-only.json).

The 82.86-second batch ran inside a coordinated 90-second pause of compiler
workers. **The host was not otherwise idle**: a known unrelated installed-Habu
process (PID 53955, previously sampled around 37.5% CPU) remained active.
These are workload observations under that load, not isolated-machine claims.
No filesystem-cache flush was performed. Raw repetitions, CPU time and
provenance are in [performance.json](results/adversarial/performance.json).
The independent reviewer checked the runner, source/binary identities, raw
results and median calculations without rerunning the timings.

The indexed implementation removes the demonstrated quadratic row/set/sort
paths: increasing zero-cost sessions fivefold increased elapsed time 5.55-fold
in this batch. Habu still took **3.53×** Zig's time on priced sessions,
**8.33–9.69×** on zero-cost sessions, and **8.88–14.25×** on scans. It uses less
peak memory, particularly when the same data is split into files; Zig's
parallel scanner is faster at 16 files. This is **not runtime parity**.
The original audit's 20k-session timings (10.6–10.9 s) and 100k timeout used a
different record shape; they establish the original scaling defect rather
than a controlled speedup ratio for this batch. No compiler/runtime defect
was established, and no Habu changes or numeric compatibility expansion
were made.

To repeat on a coordinated host:

```sh
python3 benchmark/performance.py benchmark/bin/zzusage-zig-full-small bin/zzusage \
  --output .build/performance.json --note 'Describe current host load here'
# Optionally add --baseline /absolute/path/to/the/checkpoint-binary.
```

# Original migration measurements (historical)

The accepted port targets original commit `9e060d9a767789ab6aaeb8739464bfb70da94b3e`.
At that revision, `main.f` was carried byte-for-byte from the accepted Habu candidate (40,628
bytes; SHA-256 `72ecf902ae7fb484595c72010c63fe3834a99c0c94859a13771688512b9b7399`).
That revision's Zig 0.17.0 reference had SHA-256
`eda21398bf7d187182bd57644ed5a7dac80c04038c010023b939e9b3e6e0dd24`.
Its API and ownership changes relative to Zig 0.15.2 are in
[zig-scope.txt](zig-scope.txt).

Measurements were made on macOS 27.0.1 arm64 using Habu release `c53b4d2c`
(compiler SHA-256 `ccf0798dd4e11a3ea4308386704bd09a5f183750d18b802b9b2d9c28d6af2b96`)
and Zig 0.17.0. File sizes are exact bytes on disk. The saved Habu
[size breakdown](results/full-habu-build.txt) records 78,092 bytes of
application code, 2,984 carried data bytes, and 115,836 total bytes. The
smallest Zig recipe is `-O small -fstrip -fno-unwind-tables`, then
`/usr/bin/strip -u -r` and ad hoc signing. Its saved
[measurement](results/zig-smallest-measurement.json) records the verified
signature and executable SHA-256.

| Build | Bytes | SHA-256 | Saved suite |
|---|---:|---|---|
| Habu AOT | 115,836 | `fa40f85d48ba311756d24ac382f94320876b1155b54a2e8a11ed966a003fdb7a` | Both |
| Zig full, `-O small -fstrip` | 277,864 | `8fe5756d5309423ee66b965148230f6c021373c8a5f925c76395b652862b4d9f` | [100/100](results/full-suite-small.json) |
| Zig full, smallest configuration | 236,480 | `abe6d769d371053be498b85c305b92d6c41a143c647049e8185c160a631a97d2` | [100/100](results/minimal-zig/full-suite-zzusage.json) |

Each suite has 99 exact exit/stdout/stderr comparisons and one concurrent
append case checking initial-event retention. The runner compares bytes without
normalizing output and verifies synthetic inputs stay unchanged. Historical
[parallel-order evidence](results/parallel-order.json) shows the Zig worker
scanner emitted 40 distinct daily outputs in 40 runs on 24 files; a serial
Habu scan cannot match every schedule choice. The
[focused independent follow-up](results/final-review.json) accepted the
hash-growth and actual-EOF fixes with no confirmed findings. That review
covered those fixes and affected behavior, not the whole port anew.

Those original measurements did not include execution time or peak memory. Saved output JSON includes
original candidate filesystem paths as historical provenance; the build and
test scripts in this checkout use paths relative to the repository.
