# Residual parsing and collection costs

The 82.86-second comparison in [performance-output-and-cent.json](results/adversarial/performance-output-and-cent.json)
measured the application after indexing, output buffering and cent formatting.
Its remaining scan gap was investigated with finer phase timers, CPU sampling,
and a standalone Habu reproduction. The following diagnosis led to two more
application fixes. No Habu compiler, runtime or library source was changed.

## Identified and fixed work

The same 482,800-record daily fixture was run with explicit `costUSD:0` and
with that field omitted. Before the fixes, the instrumented explicit case
spent 1.871 s inside `F64-TEXT:PARSE`, 1.897 s inside `RECORD-COST`, and 2.607 s
inside `PARSE-JSON`. Omitting the field reduced `PARSE-JSON` to 0.564 s.
The fixtures differ in input length and pricing, so this is attribution,
not a controlled before/after speedup. Outputs matched Zig within each case.
[Results](results/adversarial/residual/results.json) and
[phase counters](results/adversarial/residual/explicit-metrics.txt) retain details.

Pinned Habu `lib/f64-text.f` validates grammar, obtains a small work buffer
through `MEM-ALLOC-BYTES`, copies and NUL-terminates the spelling, saves/sets
rounding mode around `strtod_l`, restores it, and releases the buffer.
`lib/memory.f` implements that allocation with `map-anon`; release uses
`munmap`. Thus the old application crossed this OS allocation boundary for
every explicit cost, even an exact integer.

The owned-process [CPU sample](results/adversarial/residual/sample-app.txt)
contains 1,544 main-thread samples. Its leading offsets map to:

| Offset | Samples | Instruction attribution |
|---|---:|---|
| `+0xa448` | 247 | Return from Darwin `munmap` syscall 73 |
| `+0xa2a0` | 189 | Return from Darwin `mmap` syscall 197 |
| `+0x6664` | 167 | Byte store after a protection check; source word unassigned |

The first two together account for 436 samples (28.2%). These offsets were
verified against the saved pre-parser executable's SHA-256, not the rebuilt
executable: [metadata](results/adversarial/residual/sample-result.json) and
[selected disassembly](results/adversarial/residual/sample-disassembly.txt).

`28900197bd65` adds a narrow application path for complete scanned
`-?[0-9]+` tokens whose magnitude is at most `2^53`. Every accumulation step
checks the bound; conversion is exact, with the sign applied afterward to
retain negative zero. All other tokens use the unchanged float parser.
This is a structural exactness bound, not a special case for the benchmark's
zero values or a new unlimited numeric implementation.

`9cb9d64559aa` caches the last formatted epoch day. Profiling had measured
482,800 repeated calendar conversions taking about 0.408 s. The cache uses
the existing floor division, a separate valid flag, and the existing date
buffer. It preserves the original negative-day and five-digit-year behavior.

## Post-fix attribution and remaining differences

The final diagnostic build used identical fixtures, synthetic HOME and
explicit input roots. All three executables matched exit and stdout hashes:
[results](results/adversarial/residual/post-results.json). Inclusive timers
are nested and add overhead; do not sum these rows or treat them as controlled
wall-time ratios.

| Inclusive phase, 482,800 explicit-cost records | Before | After |
|---|---:|---:|
| Collection | 4.165 s | 1.467 s |
| Raw field parsing | 2.607 s | 0.545 s |
| General float parser | 1.871 s / 482,800 calls | 0 calls |
| Exact integer cost path | absent | 0.0168 s |
| Date formatting | 0.408 s | 0.0021 s |
| Timestamp parsing/calendar conversion | 0.277 s | 0.185 s |
| Set membership lookup/insertion | 0.207 s | 0.160 s |
| Field-name dispatch, inside parsing | 0.165 s | 0.129 s |
| Quote/string scanning, inside parsing | 0.156 s | 0.118 s |
| Row lookup | 0.072 s | 0.062 s |

Only the general float calls and repeated date work were targeted. Changes
in other phases are not claimed as improvements; instrumentation and host
load affect them. Raw [post-fix counters](results/adversarial/residual/post-explicit-metrics.txt)
and the [omitted-cost case](results/adversarial/residual/post-omitted-metrics.txt)
show one file pass and no repeated history scan.

Remaining source-level differences explain where further investigation would
belong, without assigning unmeasured fractions of the gap:

- Habu's raw scanner walks bytes and checks field names sequentially. Zig
  dispatches first by initial byte and length and uses its standard memory
  search routines. The smaller field/scanning phases have millions of timer
  invocations; their readings include material measurement overhead.
- Habu's compatible Wyhash assembles fixed-width integers from bytes and
  decomposes wide multiplication into four 32-bit products. Zig's Wyhash uses
  fixed-width loads and a native 128-bit product. Both use indexed lookups;
  the repaired application no longer scans every previous row or membership.
- Both implementations retain forward calendar arithmetic from 1970.
  Timestamp conversion remains per event; the application date-output cache
  removes repeated rendering without changing timestamp parsing semantics.
- High-cardinality reports still spend time in collection, stable sorting and
  rendering. Habu uses the generic checked heapsort with a comparator and
  explicit tie ranks. Zig specializes its row sort. Changing the data layout,
  native byte operations or sort implementation would be a separate change,
  rather than another demonstrated single dominant defect.
- Habu scans files serially; Zig starts workers at ten files. That algorithmic
  difference remains deliberate and explains part of the multi-file advantage
  while Habu uses less peak memory. It does not explain the one-file gap.

No additional dominant application cause or compiler correctness defect was
established. More aggressive scanner/hash/sort specialization would need a
separate measured design and compatibility review. The current changes stop
at the two straightforward causes supported by these measurements.

## Standalone Habu library reproduction

[parse-probe.f](parse-probe.f) performs 241,400 pairs of `F64-TEXT:PARSE` calls
on `0` and `1.25`, consumes their IEEE bits into a checksum, and reports
monotonic nanoseconds. The saved [diagnostic result](results/adversarial/residual/repro-result.json)
records 482,800 conversions in 1,446,492,209 ns, exit zero, and the expected
checksum. This isolates the library conversion cost without scanning logs or
running zzusage; it is not a controlled comparison with another parser.

```sh
HABU_ROOT=/absolute/path/to/habu/c53b4d2c python3 benchmark/parse-probe.py
```

The runner builds in ignored `.build/parse-probe`, sets synthetic HOME, runs
only those two literal inputs, checks the checksum, and writes result metadata.
A possible Habu library improvement is a caller-owned work buffer or a suitable
allocation API that avoids per-conversion map/unmap while retaining rounding,
locale, concurrency and error semantics. Fractional/exponent costs still use
that general parser. This is a library performance opportunity, not an
established compiler defect; it was reported rather than implemented here.

Both full CLI suites passed **142/142**. Independent review added
[104 exact differential cases](results/adversarial/residual-review.json),
covering 188 numeric tokens and date/cache transitions. It found no defects.

## Final existing-binary comparison

The final 47.72-second, 45-run comparison used three alternating repetitions
of Zig, checkpoint `8a698638`, and final source `9cb9d645` on the same five
synthetic inputs. One-file/16-file scan medians changed from 3.570/3.902 s to
1.349/1.283 s: **2.65×/3.04× faster** after the two fixes. The final priced
report took 0.813 s versus Zig's 0.242 s. All outputs matched and input hashes
stayed unchanged. [Full results and memory](evidence.md) and
[raw repetitions](results/adversarial/performance.json) retain every run.

The run finished at 13:12:30 UTC within the compiler-worker pause ending at
13:12:51. The host was not idle: unrelated PID 53955 had been sampled at
95.0% CPU immediately before the window. These observations do not establish
isolated-machine timing or remove the remaining Zig performance advantage.
