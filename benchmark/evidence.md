# Full CLI migration evidence

The accepted port targets original commit `9e060d9a767789ab6aaeb8739464bfb70da94b3e`.
`main.f` is carried byte-for-byte from the accepted Habu candidate (40,628
bytes; SHA-256 `72ecf902ae7fb484595c72010c63fe3834a99c0c94859a13771688512b9b7399`).
The Zig 0.17.0 reference in `zig-full/main.zig` has SHA-256
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

No benchmark measured execution time or peak memory. Saved output JSON includes
original candidate filesystem paths as historical provenance; the build and
test scripts in this checkout use paths relative to the repository.
