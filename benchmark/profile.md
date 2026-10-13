# Runtime attribution — 2026-10-13

The indexed checkpoint `55e3a1cd` had removed quadratic aggregation, but still
spent most of its report time in output and monetary formatting. Two measured
application changes addressed those costs: bounded output buffering
(`225aa049`) and fixed-cent formatting (`82c12e09`). Habu release `c53b4d2c`,
the original Zig branch, and the reference were unchanged during this work.

## CPU samples and phase timers

The profiling fixture contains 100,000 distinct sessions in one 18,900,000-byte
JSONL file. It uses Sonnet 4.5 pricing, input counts `1000 + i % 100`, output
200, cache creation 30, cache reads 40, and dates cycling through January 1–28,
2026. There is no explicit cost override. This flat-field fixture differs
from the nested, mixed-model case used for the final controlled comparison.
All runs used synthetic HOME and an explicit fixture root.

The macOS CPU [sample before buffering](results/adversarial/profile/baseline-sample.txt)
placed 3,582 of 4,230 samples (84.7%) at executable offset `0x6358`, immediately
after the `write` syscall. Disassembly at `0x6350` is `mov x16, #4`, followed
by `svc #0x80` and then `cset`; this is the native write wrapper, not a parser
or allocator stall. The [final sample](results/adversarial/profile/final-sample.txt)
has 635 samples distributed across application work, with 35 at its write
wrapper. The programs are stripped, so phase instrumentation provides names.

The [instrumentation script](profile-phases.py) creates a temporary source copy
with monotonic inclusive timers and call counters. It does not change the
application source. These runs include timer overhead and were **not** taken
in the controlled benchmark window; use them for attribution, not speedup
ratios. Nested rows overlap and must not be summed.

| Phase (seconds) | Indexed checkpoint | After buffering | After cent path |
|---|---:|---:|---:|
| Collect, including read/parse/aggregate | 0.440 | 0.441 | 0.464 |
| Parse fields | 0.059 | 0.060 | 0.064 |
| Timestamp conversion | 0.049 | 0.049 | 0.054 |
| Find/create row | 0.106 | 0.102 | 0.114 |
| Membership insertion | 0.054 | 0.056 | 0.058 |
| Compute event cost | 0.011 | 0.016 | 0.011 |
| Row capacity checks | 0.024 | 0.027 | 0.027 |
| String pool insertion | 0.014 | 0.015 | 0.015 |
| Sort rows | 0.148 | 0.150 | 0.162 |
| Render report, including formatting/writes | 13.825 | 2.645 | 0.360 |
| Monetary formatting, including its writes | 3.016 | 2.130 | 0.019 |
| Write syscalls | 11.405 | 0.138 | 0.027 |
| Read syscalls | 0.003 | 0.002 | 0.002 |
| Write calls | 4,400,047 | 2,811 | 2,811 |

Each run wrote the same 11,500,133 bytes. Raw phase results:
[checkpoint](results/adversarial/profile/phase-metrics.txt),
[buffer](results/adversarial/profile/buffer-phase-metrics.txt),
[final](results/adversarial/profile/fast-phase-metrics.txt).
The final counters show one file pass and 100,000 parse, timestamp, row lookup,
membership and pricing calls. There is no repeated history scan. The capacity
counter records checks, not that many allocations. No measured allocator
bottleneck or compiler/runtime defect was established at this stage.

A separate [scan probe](results/adversarial/profile/scan-phase-metrics.txt)
used the final instrumented executable on the benchmark's 482,800-record
explicit-zero-cost file. Collection took 3.253 s, of which field parsing took
1.895 s and timestamp conversion 0.225 s. It performed one file pass, 13 reads,
and one 224-byte write; sorting/rendering were negligible. Its output matched
Zig ([result](results/adversarial/profile/scan-phase-result.json)). The residual
scan gap is principally collection and parsing, not report writes or rescans.
This does not establish the cost of every parser subroutine separately.

## Bounded changes and correctness

The 4 KiB output buffer retains partial-write handling and propagates report
errors at flush. Help retains its original error behavior. Tests include
values spanning the buffer boundary and a reader that closes after consuming
a prefix of a large report.

For finite monetary values with strict magnitude below `2^43`, cents can be
rounded without generating a general shortest-decimal string. The half-cent
threshold and adjacent binary64 values were reviewed independently; signs,
zero, magnitude boundaries, subnormals, and carries are covered. Larger and
nonfinite values keep the existing bounded formatter. The implementation adds
no unbounded integers and does not change numeric compatibility.

Independent probes compared 2,785 threshold-neighbor values and the previous
950-value fallback corpus; a separate generated corpus compared 97,044
monetary values against actual Zig output. Both full CLI suites passed
136/136. The reviewer found no actionable buffer or cent-path defects.

## Repeat and interpret

To generate a diagnostic source copy:

```sh
python3 benchmark/profile-phases.py main.f .build/profile/phase.f
```

Build the copy with the pinned Habu `tools/hb-build.f` recipe used by
`build.sh`, choosing an ignored output path. Run it only with a synthetic HOME
and explicit synthetic `--data-dir`; save stderr metrics and compare stdout
with the uninstrumented executable. CPU samples were captured with macOS
`sample` against these owned test processes only. Phase instrumentation is
for diagnosis; the separate [performance runner](performance.py) measures
unaltered executables.

The output/cent same-input, same-batch comparison measured the indexed checkpoint
at 16.269 s and the optimized application at 0.889 s: **18.31× faster**. Zig
still took 0.252 s, and the scan-heavy cases retain larger gaps. The complete
wall/CPU/RSS observations and the known background-load qualification are in
[saved batch](results/adversarial/performance-output-and-cent.json) and
[evidence.md](evidence.md). Runtime parity is not claimed.

Further residual analysis identified and repaired per-cost native allocation
and repeated date rendering. See [residual.md](residual.md) for CPU samples,
a standalone Habu reproduction, post-fix phase attribution, and the boundary
between these application fixes and possible Habu library work.
