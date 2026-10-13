# zzusage agent notes

This branch contains the Habu full CLI port of the original Zig application.
The original is preserved on the `zig` branch. `main.f` is the application;
`build.sh` compiles it with pinned Habu release `c53b4d2c` (see README).
`benchmark/zig-full/main.zig` is the Zig 0.17.0 differential reference, with
API adaptations and allocator ownership repairs documented in
`benchmark/zig-scope.txt`.

## Work and checks

- Build from the repository root with `sh build.sh`; output and compiler state
  belong in ignored `bin/` and `.build/`.
- Build the reference with `sh benchmark/build-zig.sh`, then run
  `python3 test.py benchmark/bin/zzusage-zig-full-small bin/zzusage`.
  The runner creates synthetic input and sets child `HOME` to its temporary
  fixture root; never use real Claude logs for differential tests.
- Set `ZZUSAGE_TEST_OUTPUT_DIR` to move test fixtures/results elsewhere. The
  default is ignored `.build/test-results/`. The full suite includes sparse
  files at the inclusive 512 MiB boundary, so allow sufficient space/time.
- `sh benchmark/build-zig-smallest.sh` reproduces the macOS size variant; it
  needs Zig 0.17.0 plus Apple's `strip` and `codesign`.

## Behavioral invariants

- Keep command parsing permissive, including aliases `weekly` and `blocks`
  rendering daily reports, and `--order` consuming a value without reordering.
- Preserve the original raw JSONL field scanner, historical pricing formula,
  date arithmetic, JSON bytes, ANSI table formatting, and output errors. Help
  still prints “(Zig)” for exact CLI compatibility.
- Scan regular `.jsonl` files recursively and through actual EOF, accepting
  exactly 512 MiB but skipping larger files. Habu's scan is serial; Zig's
  threaded scan can produce variable order at ten or more files. See
  `full-parity.md` for the detailed behavior ledger.
- Judge deterministic cases by exact exit/stdout/stderr bytes. The one
  concurrent-append fixture checks retention of the initial event, since
  append counts are inherently variable.

The saved macOS arm64 measurements and scoped review are listed in
`benchmark/evidence.md`; neither runtime speed nor peak memory was measured.
