# Current audit and repair evidence

The independent [adversarial audit](audit.md) found failures missed by the
original 100-case suite. The repaired code was freshly built with pinned Habu
`c53b4d2c` and Zig 0.17.0 on macOS arm64. The full synthetic suite passed
**131/131 against each Zig size configuration**, including exact exit/stdout/
stderr comparisons and one nondeterministic append-retention check:
[small](results/adversarial/full-suite-small.json),
[smallest](results/adversarial/full-suite-smallest.json).
Verbose stdout is omitted in these saved summaries; `test.py` generates it
in ignored `.build/test-results/`. Input integrity is checked by the runner.
The [independent repair review](results/adversarial/review.json) found no
remaining defects, including its follow-up stdout/stderr failure matrix.

## Binary size

| Executable | Bytes | SHA-256 |
|---|---:|---|
| Habu AOT | 115,836 | `75960883946bfcbe4ba9181da6c3e06643a5a0bebd4db268d8837360e30fdf6f` |
| Zig stripped small | 277,912 | `1a74d7c7598a63be80bda00fa7d604fa13e1ebac41dec419c934080225acbb4b` |
| Zig smallest | 236,480 | `e0368efb53c045b5abc895f60376bdf0dafd1536c560a39243e2eca1972d58ec` |

The Habu executable remains **115,836 bytes**, 51.0% smaller than the smallest
measured Zig build. Its application code grew from 78,092 to 82,332 bytes and
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
records totaling 67,109,200 bytes. Synthetic records explicitly cost zero;
these measurements isolate scan/aggregation/output workloads and do not
represent a mix of model pricing or arbitrary monetary formatting.

| Workload | Zig median seconds | Habu median seconds | Zig median MiB RSS | Habu median MiB RSS |
|---|---:|---:|---:|---:|
| one-file-64MiB | 0.375 | 3.404 | 254.62 | 129.72 |
| 16-files-64MiB | 0.209 | 3.103 | 169.36 | 9.72 |
| 20000-sessions | 0.023 | 2.604 | 23.80 | 9.53 |
| 100000-sessions | 0.100 | 13.511 | 100.62 | 39.14 |

The 70.17-second batch ran inside a coordinated 90-second pause of compiler
workers. **The host was not otherwise idle**: a known unrelated installed-Habu
process (PID 53955, previously sampled around 37.5% CPU) remained active.
These are workload observations under that load, not isolated-machine claims.
No filesystem-cache flush was performed. Raw repetitions, CPU time and
provenance are in [performance.json](results/adversarial/performance.json).

The indexed implementation removes the demonstrated quadratic row/set/sort
paths: increasing sessions fivefold increased elapsed time about 5.2-fold in
this batch. Habu nevertheless remains approximately 9–15× slower on these
scan workloads and 112–135× slower on these session reports. Its serial scan
uses less peak memory, particularly when the same data is split into files;
Zig's parallel scanner is faster at 16 files. This is **not runtime parity**.
The old audit's 20k-session timings (10.6–10.9 s) and 100k timeout used a
different, price-bearing record shape, so they are failure evidence rather
than a controlled before/after speedup ratio for this batch.

To repeat on a coordinated host:

```sh
python3 benchmark/performance.py benchmark/bin/zzusage-zig-full-small bin/zzusage \
  --output .build/performance.json --note 'Describe current host load here'
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
